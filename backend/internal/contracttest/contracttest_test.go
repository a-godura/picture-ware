package contracttest

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/getkin/kin-openapi/openapi3"
)

func TestSpecIsValid(t *testing.T) {
	Spec(t)
}

// TestDeployedRoutesMatchContract covers every route in template.yaml, trips
// and legacy /photos alike.
func TestDeployedRoutesMatchContract(t *testing.T) {
	CheckDeployedRoutes(t)
}

func TestPlanned(t *testing.T) {
	for _, tt := range []struct {
		yaml string
		want bool
	}{
		{"x-planned: true", true},
		{"x-planned: false", false},
		{`x-planned: "true"`, false}, // only a real boolean counts
		{"x-other: true", false},
		{"", false},
	} {
		doc := loadDoc(t, "/a", "      "+tt.yaml)
		if got := Planned(doc.Paths.Value("/a").Get); got != tt.want {
			t.Errorf("%q: Planned = %v, want %v", tt.yaml, got, tt.want)
		}
	}
}

func TestCompareRoutes(t *testing.T) {
	// GET /done is deployed; GET /later is planned.
	doc := loadDoc(t, "/done", "", "/later", "      x-planned: true")
	for _, tt := range []struct {
		name     string
		deployed []string
		wantErr  string
	}{
		{"planned op skipped", []string{"GET /done"}, ""},
		{"planned op deployed anyway", []string{"GET /done", "GET /later"}, "GET /later is marked x-planned: true"},
		{"documented op missing", nil, "routes differ"},
		{"undocumented route deployed", []string{"GET /done", "POST /x"}, "routes differ"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			err := compareRoutes(doc, tt.deployed)
			if tt.wantErr == "" {
				if err != nil {
					t.Fatal(err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
				t.Fatalf("err = %v, want %q", err, tt.wantErr)
			}
		})
	}
}

// loadDoc builds a minimal spec with a GET operation per path; pathsAndExtras
// alternates a path and extra YAML lines for its operation.
func loadDoc(t *testing.T, pathsAndExtras ...string) *openapi3.T {
	t.Helper()
	var b strings.Builder
	b.WriteString("openapi: 3.0.3\ninfo: {title: t, version: \"1\"}\npaths:\n")
	for i := 0; i < len(pathsAndExtras); i += 2 {
		fmt.Fprintf(&b, "  %s:\n    get:\n%s\n      responses:\n        \"200\": {description: ok}\n", pathsAndExtras[i], pathsAndExtras[i+1])
	}
	doc, err := openapi3.NewLoader().LoadFromData([]byte(b.String()))
	if err != nil {
		t.Fatalf("%v\n%s", err, b.String())
	}
	if err := doc.Validate(context.Background()); err != nil {
		t.Fatal(err)
	}
	return doc
}
