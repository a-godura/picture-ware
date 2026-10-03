package contracttest

import "testing"

func TestSpecIsValid(t *testing.T) {
	Spec(t)
}

// TestDeployedRoutesMatchContract covers every route in template.yaml, trips
// and legacy /photos alike.
func TestDeployedRoutesMatchContract(t *testing.T) {
	CheckDeployedRoutes(t)
}

func TestPlanned(t *testing.T) {
	doc := Spec(t)
	planned := 0
	for _, item := range doc.Paths.Map() {
		for _, op := range item.Operations() {
			if Planned(op) {
				planned++
			}
		}
	}
	t.Logf("%d planned (not yet deployed) operations", planned)
	if op := doc.Paths.Value("/trips").Get; Planned(op) {
		t.Fatal("GET /trips is deployed, not planned")
	}
}
