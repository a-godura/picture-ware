// Package contracttest checks handler responses against the API contract
// (api/openapi.yaml) and the routes deployed in template.yaml against the
// routes it documents. It is used only from tests: every API handler's tests
// pass their responses through Check, so a response that doesn't match the
// contract fails the build.
package contracttest

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"

	"github.com/aws/aws-lambda-go/events"
	"github.com/getkin/kin-openapi/openapi3"
	"github.com/getkin/kin-openapi/openapi3filter"
	"github.com/getkin/kin-openapi/routers"
	"gopkg.in/yaml.v3"
)

const (
	specFile     = "api/openapi.yaml"      // relative to the repo root
	templateFile = "backend/template.yaml" // relative to the repo root
)

// repoRoot walks up from the working directory (a package directory under
// go test) to the directory containing api/openapi.yaml.
func repoRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, specFile)); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", errors.New(specFile + " not found above the working directory")
		}
		dir = parent
	}
}

// HTML responses (the public invite landing page) are checked as plain
// strings: content type, status and that the body is text.
func init() {
	openapi3filter.RegisterBodyDecoder("text/html", func(r io.Reader, _ http.Header, _ *openapi3.SchemaRef, _ openapi3filter.EncodingFn) (any, error) {
		b, err := io.ReadAll(r)
		return string(b), err
	})
}

var loadSpec = sync.OnceValues(func() (*openapi3.T, error) {
	root, err := repoRoot()
	if err != nil {
		return nil, err
	}
	doc, err := openapi3.NewLoader().LoadFromFile(filepath.Join(root, specFile))
	if err != nil {
		return nil, err
	}
	return doc, doc.Validate(context.Background())
})

// Spec returns the parsed, validated contract or fails the test.
func Spec(t testing.TB) *openapi3.T {
	t.Helper()
	doc, err := loadSpec()
	if err != nil {
		t.Fatalf("load %s: %v", specFile, err)
	}
	return doc
}

// Check fails the test if resp isn't a documented response of the route in
// req. Requests without a JWT never reach the Lambda in production (API
// Gateway answers 401 itself) but the Lambda's own 401 is documented too.
func Check(t testing.TB, req events.APIGatewayV2HTTPRequest, resp events.APIGatewayV2HTTPResponse) {
	t.Helper()
	doc := Spec(t)
	method, path, _ := strings.Cut(req.RouteKey, " ")
	item := doc.Paths.Value(path)
	var op *openapi3.Operation
	if item != nil {
		op = item.GetOperation(method)
	}
	if op == nil {
		// Unknown routes never reach the Lambda through API Gateway; just
		// require the standard error shape.
		if resp.StatusCode != http.StatusNotFound || !strings.Contains(resp.Body, `"error"`) {
			t.Fatalf("undocumented route %q answered %d %s", req.RouteKey, resp.StatusCode, resp.Body)
		}
		return
	}

	httpReq := httptest.NewRequest(method, "https://api.example"+fillPath(path, req.PathParameters), nil)
	header := http.Header{}
	for k, v := range resp.Headers {
		header.Set(k, v)
	}
	in := &openapi3filter.ResponseValidationInput{
		RequestValidationInput: &openapi3filter.RequestValidationInput{
			Request: httpReq,
			Route:   &routers.Route{Spec: doc, Path: path, PathItem: item, Method: method, Operation: op},
			Options: &openapi3filter.Options{IncludeResponseStatus: true, AuthenticationFunc: openapi3filter.NoopAuthenticationFunc},
		},
		Status: resp.StatusCode,
		Header: header,
		Body:   io.NopCloser(bytes.NewReader([]byte(resp.Body))),
		Options: &openapi3filter.Options{
			IncludeResponseStatus: true,
			MultiError:            true,
		},
	}
	if err := openapi3filter.ValidateResponse(context.Background(), in); err != nil {
		t.Fatalf("contract violation for %s -> %d %s:\n%v", req.RouteKey, resp.StatusCode, resp.Body, err)
	}
}

// fillPath substitutes path parameters, escaping them so that test values
// such as "../x" still produce a parseable URL.
func fillPath(path string, params map[string]string) string {
	for k, v := range params {
		path = strings.ReplaceAll(path, "{"+k+"}", url.PathEscape(v))
	}
	return path
}

// PlannedExtension marks an operation that is in the contract but not
// deployed yet ("x-planned: true"), so a contract PR can land before the
// backend PR that implements it. The backend PR removes the marker in the
// same change that adds the route to template.yaml.
const PlannedExtension = "x-planned"

// Planned reports whether op is marked x-planned: true.
func Planned(op *openapi3.Operation) bool {
	v, ok := op.Extensions[PlannedExtension]
	return ok && v == true
}

// CheckDeployedRoutes fails the test unless the HttpApi events in
// template.yaml are exactly the contract's operations that aren't planned.
func CheckDeployedRoutes(t testing.TB) {
	t.Helper()
	if err := compareRoutes(Spec(t), deployedRoutes(t)); err != nil {
		t.Fatal(err)
	}
}

// compareRoutes returns an error unless deployed ("METHOD /path") is exactly
// the contract's operations without x-planned: true. It fails safe: a
// planned operation that is deployed anyway is an error (remove the marker),
// as is anything deployed but undocumented, or documented and not planned
// but missing.
func compareRoutes(doc *openapi3.T, deployed []string) error {
	var documented, planned []string
	for path, item := range doc.Paths.Map() {
		for method, op := range item.Operations() {
			if Planned(op) {
				planned = append(planned, method+" "+path)
			} else {
				documented = append(documented, method+" "+path)
			}
		}
	}
	isDeployed := map[string]bool{}
	for _, r := range deployed {
		isDeployed[r] = true
	}
	sort.Strings(planned)
	for _, r := range planned {
		if isDeployed[r] {
			return fmt.Errorf("%s is marked %s: true in %s but deployed in %s: remove the marker", r, PlannedExtension, specFile, templateFile)
		}
	}
	deployed = append([]string(nil), deployed...)
	sort.Strings(documented)
	sort.Strings(deployed)
	if strings.Join(documented, "\n") == strings.Join(deployed, "\n") {
		return nil
	}
	return fmt.Errorf("routes differ (operations marked %s: true are left out)\n"+
		"contract, deployed operations (%s):\n  %s\ncontract, planned:\n  %s\n%s:\n  %s",
		PlannedExtension, specFile, strings.Join(documented, "\n  "), strings.Join(planned, "\n  "),
		templateFile, strings.Join(deployed, "\n  "))
}

// deployedRoutes lists the HttpApi events in template.yaml.
func deployedRoutes(t testing.TB) []string {
	t.Helper()
	root, err := repoRoot()
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(root, templateFile))
	if err != nil {
		t.Fatal(err)
	}
	var doc yaml.Node
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	var deployed []string
	walk(&doc, func(n *yaml.Node) {
		// An HttpApi event: a mapping with Type: HttpApi and Properties.Method/Path.
		if n.Kind != yaml.MappingNode || value(n, "Type") != "HttpApi" {
			return
		}
		if props := child(n, "Properties"); props != nil {
			deployed = append(deployed, strings.ToUpper(value(props, "Method"))+" "+value(props, "Path"))
		}
	})
	return deployed
}

func walk(n *yaml.Node, f func(*yaml.Node)) {
	f(n)
	for _, c := range n.Content {
		walk(c, f)
	}
}

func child(m *yaml.Node, key string) *yaml.Node {
	for i := 0; i+1 < len(m.Content); i += 2 {
		if m.Content[i].Value == key {
			return m.Content[i+1]
		}
	}
	return nil
}

func value(m *yaml.Node, key string) string {
	if c := child(m, key); c != nil && c.Kind == yaml.ScalarNode {
		return c.Value
	}
	return ""
}
