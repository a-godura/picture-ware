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
