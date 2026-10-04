package main

import (
	"bytes"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

const spec = `openapi: 3.0.3
info: {title: t, version: "1"}
paths:
  /live:
    get:
      operationId: live
      responses: {"200": {description: ok}}
  /mixed:
    parameters:
      - {name: x, in: query, schema: {type: string}}
    get:
      operationId: mixedLive
      responses: {"200": {description: ok}}
    post:
      operationId: mixedPlanned
      x-planned: true
      responses: {"200": {description: ok}}
  /planned/{id}:
    parameters:
      - {name: id, in: path, required: true, schema: {type: string}}
    get:
      operationId: plannedGet
      x-planned: true
      responses: {"200": {description: ok}}
    delete:
      operationId: plannedDelete
      x-planned: true
      responses: {"204": {description: gone}}
  /notReallyPlanned:
    get:
      operationId: stringTrue
      x-planned: "true"
      responses: {"200": {description: ok}}
    put:
      operationId: falseFlag
      x-planned: false
      responses: {"200": {description: ok}}
components:
  schemas:
    Kept: {type: string}
`

func TestDropPlanned(t *testing.T) {
	var out bytes.Buffer
	if err := run(strings.NewReader(spec), &out); err != nil {
		t.Fatal(err)
	}
	var got struct {
		Paths      map[string]map[string]any `yaml:"paths"`
		Components map[string]any            `yaml:"components"`
	}
	if err := yaml.Unmarshal(out.Bytes(), &got); err != nil {
		t.Fatalf("output isn't YAML: %v\n%s", err, out.String())
	}
	var ops []string
	for path, item := range got.Paths {
		for method, op := range item {
			if methods[method] {
				ops = append(ops, path+" "+method+" "+op.(map[string]any)["operationId"].(string))
			}
		}
	}
	want := map[string]bool{
		"/live get live": true, "/mixed get mixedLive": true,
		"/notReallyPlanned get stringTrue": true, "/notReallyPlanned put falseFlag": true,
	}
	if len(ops) != len(want) {
		t.Fatalf("operations = %v", ops)
	}
	for _, op := range ops {
		if !want[op] {
			t.Fatalf("unexpected operation %q in %v", op, ops)
		}
	}
	if _, ok := got.Paths["/planned/{id}"]; ok {
		t.Error("path with only planned operations kept")
	}
	if _, ok := got.Paths["/mixed"]["parameters"]; !ok {
		t.Error("path-level parameters of a kept path dropped")
	}
	if got.Components == nil {
		t.Error("components dropped")
	}
}

func TestRejectsGarbage(t *testing.T) {
	for _, in := range []string{"- a list\n", "paths: [1, 2]\n", ": : :\n"} {
		if err := run(strings.NewReader(in), &bytes.Buffer{}); err == nil {
			t.Errorf("accepted %q", in)
		}
	}
}

func TestNoPaths(t *testing.T) {
	var out bytes.Buffer
	if err := run(strings.NewReader("openapi: 3.0.3\n"), &out); err != nil || !strings.Contains(out.String(), "openapi") {
		t.Fatalf("%v %q", err, out.String())
	}
}
