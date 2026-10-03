package api

// Contract tests: every response the handler produces in this package's tests
// must match api/openapi.yaml, and the routes deployed in template.yaml must be
// exactly the routes the contract documents.

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
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
	specPath     = "../../../api/openapi.yaml"
	templatePath = "../../template.yaml"
)

var loadSpec = sync.OnceValues(func() (*openapi3.T, error) {
	doc, err := openapi3.NewLoader().LoadFromFile(specPath)
	if err != nil {
		return nil, err
	}
	return doc, doc.Validate(context.Background())
})

func spec(t *testing.T) *openapi3.T {
	t.Helper()
	doc, err := loadSpec()
	if err != nil {
		t.Fatalf("load %s: %v", specPath, err)
	}
	return doc
}

// handleT calls Handle and checks the response against the contract.
func (h *Handler) handleT(t *testing.T, req events.APIGatewayV2HTTPRequest) (events.APIGatewayV2HTTPResponse, error) {
	t.Helper()
	resp, err := h.Handle(context.Background(), req)
	if err == nil {
		checkContract(t, req, resp)
	}
	return resp, err
}

// checkContract fails the test if resp isn't a documented response of the
// route in req. Requests without a JWT never reach the Lambda in production
// (API Gateway answers 401 itself) but the Lambda's own 401 is documented too.
func checkContract(t *testing.T, req events.APIGatewayV2HTTPRequest, resp events.APIGatewayV2HTTPResponse) {
	t.Helper()
	doc := spec(t)
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

func fillPath(path string, params map[string]string) string {
	for k, v := range params {
		path = strings.ReplaceAll(path, "{"+k+"}", v)
	}
	return path
}

func TestSpecIsValid(t *testing.T) {
	spec(t)
}

// TestDeployedRoutesMatchContract compares the HttpApi events in template.yaml
// with the operations in the contract.
func TestDeployedRoutesMatchContract(t *testing.T) {
	var documented []string
	for path, item := range spec(t).Paths.Map() {
		for method := range item.Operations() {
			documented = append(documented, method+" "+path)
		}
	}

	raw, err := os.ReadFile(templatePath)
	if err != nil {
		t.Fatal(err)
	}
	var root yaml.Node
	if err := yaml.Unmarshal(raw, &root); err != nil {
		t.Fatal(err)
	}
	var deployed []string
	walk(&root, func(n *yaml.Node) {
		// An HttpApi event: a mapping with Type: HttpApi and Properties.Method/Path.
		if n.Kind != yaml.MappingNode || value(n, "Type") != "HttpApi" {
			return
		}
		if props := child(n, "Properties"); props != nil {
			deployed = append(deployed, strings.ToUpper(value(props, "Method"))+" "+value(props, "Path"))
		}
	})

	sort.Strings(documented)
	sort.Strings(deployed)
	if strings.Join(documented, "\n") != strings.Join(deployed, "\n") {
		t.Fatalf("routes differ\ncontract (api/openapi.yaml):\n  %s\ntemplate.yaml:\n  %s",
			strings.Join(documented, "\n  "), strings.Join(deployed, "\n  "))
	}
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
