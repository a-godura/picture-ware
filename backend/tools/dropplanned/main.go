// Command dropplanned removes the operations marked "x-planned: true" from
// an OpenAPI document (and paths left without operations), so CI can check
// a contract change for breaking changes against main's *deployed* API only.
// Planned operations were never deployed, so no client depends on them and
// they may change freely until their backend PR removes the marker.
//
//	go run ./tools/dropplanned < base.yaml > base-deployed.yaml
package main

import (
	"fmt"
	"io"
	"os"

	"gopkg.in/yaml.v3"
)

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "dropplanned:", err)
		os.Exit(1)
	}
}

func run(in io.Reader, out io.Writer) error {
	var doc yaml.Node
	if err := yaml.NewDecoder(in).Decode(&doc); err != nil {
		return fmt.Errorf("parse: %w", err)
	}
	dropped, err := dropPlanned(&doc)
	if err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "dropplanned: removed %d planned operation(s)\n", dropped)
	enc := yaml.NewEncoder(out)
	enc.SetIndent(2)
	if err := enc.Encode(&doc); err != nil {
		return fmt.Errorf("write: %w", err)
	}
	return enc.Close()
}

var methods = map[string]bool{
	"get": true, "put": true, "post": true, "delete": true,
	"options": true, "head": true, "patch": true, "trace": true,
}

// dropPlanned edits doc in place and returns how many operations it removed.
func dropPlanned(doc *yaml.Node) (int, error) {
	if doc.Kind != yaml.DocumentNode || len(doc.Content) != 1 || doc.Content[0].Kind != yaml.MappingNode {
		return 0, fmt.Errorf("not an OpenAPI document")
	}
	paths := child(doc.Content[0], "paths")
	if paths == nil {
		return 0, nil
	}
	if paths.Kind != yaml.MappingNode {
		return 0, fmt.Errorf("paths is not a mapping")
	}
	dropped := 0
	var keptPaths []*yaml.Node
	for i := 0; i+1 < len(paths.Content); i += 2 {
		item := paths.Content[i+1]
		var kept []*yaml.Node
		ops := 0
		for j := 0; j+1 < len(item.Content); j += 2 {
			k, v := item.Content[j], item.Content[j+1]
			if methods[k.Value] {
				if planned(v) {
					dropped++
					continue
				}
				ops++
			}
			kept = append(kept, k, v)
		}
		if ops == 0 && len(kept) != len(item.Content) {
			continue // every operation was planned: drop the path too
		}
		item.Content = kept
		keptPaths = append(keptPaths, paths.Content[i], item)
	}
	paths.Content = keptPaths
	return dropped, nil
}

// planned reports whether an operation has x-planned: true (a real boolean).
func planned(op *yaml.Node) bool {
	v := child(op, "x-planned")
	return v != nil && v.Kind == yaml.ScalarNode && v.Tag == "!!bool" && v.Value == "true"
}

func child(m *yaml.Node, key string) *yaml.Node {
	if m.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(m.Content); i += 2 {
		if m.Content[i].Value == key {
			return m.Content[i+1]
		}
	}
	return nil
}
