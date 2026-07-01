package test

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// moduleDir resolves the path to the root module (one level up from tests/).
func moduleDir(t *testing.T) string {
	t.Helper()
	abs, err := filepath.Abs("..")
	require.NoError(t, err, "failed to resolve module directory")
	return abs
}

// tofuOptions returns terraform.Options configured for credential-free plan/validate runs.
func tofuOptions(t *testing.T, vars map[string]interface{}) *terraform.Options {
	t.Helper()
	return &terraform.Options{
		TerraformDir:    moduleDir(t),
		TerraformBinary: "tofu",
		Vars:            vars,
		// No credentials needed for validate/plan with -input=false — validation
		// blocks fire before any provider API calls.
		EnvVars: map[string]string{
			"GOOGLE_CREDENTIALS": "{}",
		},
		NoColor: true,
	}
}

// printReport emits a human-readable summary of the test suite to stdout.
func printReport(t *testing.T, results map[string]string) {
	t.Helper()
	fmt.Println()
	fmt.Println("=== GCE Instance Module Test Report ===")
	fmt.Printf("%-60s  %s\n", "Test", "Result")
	fmt.Println(strings.Repeat("-", 70))
	passed, failed := 0, 0
	for name, result := range results {
		fmt.Printf("%-60s  %s\n", name, result)
		if result == "PASS" {
			passed++
		} else {
			failed++
		}
	}
	fmt.Println(strings.Repeat("-", 70))
	fmt.Printf("Total: %d passed, %d failed\n", passed, failed)
	fmt.Println("========================================")
	fmt.Println()
}

// validSubnetSelfLink is a well-formed GCP subnetwork self-link for testing.
const validSubnetSelfLink = "https://www.googleapis.com/compute/v1/projects/stratum-dev-sandbox/regions/europe-west1/subnetworks/stratum-dev-subnet"

// validNic returns a single-entry network_interfaces slice as a Go map (HCL object).
func validNic() map[string]interface{} {
	return map[string]interface{}{
		"subnetwork":         validSubnetSelfLink,
		"network_ip":         nil,
		"assign_external_ip": false,
		"external_ip":        nil,
	}
}

// validVars returns a complete, valid set of module inputs for a single-instance list.
func validVars() map[string]interface{} {
	return map[string]interface{}{
		"environment": "dev",
		"project_id":  "stratum-dev-sandbox",
		"name_prefix": "stratum-dev",
		"instances": []map[string]interface{}{
			{
				"name":         "bastion",
				"machine_type": "e2-micro",
				"zone":         "europe-west1-b",
				"boot_image":   "ubuntu-os-cloud/ubuntu-2404-lts-amd64",
				"network_interfaces": []map[string]interface{}{
					validNic(),
				},
			},
		},
	}
}

// ── Positive test ─────────────────────────────────────────────────────────────

// TestGceInstanceValidate confirms the module initialises and validates with well-formed inputs.
func TestGceInstanceValidate(t *testing.T) {
	t.Parallel()

	opts := tofuOptions(t, validVars())

	_, initErr := terraform.InitE(t, opts)
	assert.NoError(t, initErr, "tofu init should succeed")

	_, validateErr := terraform.RunTerraformCommandE(t, opts, "validate")
	assert.NoError(t, validateErr, "tofu validate should succeed with valid inputs")

	result := "PASS"
	if initErr != nil || validateErr != nil {
		result = "FAIL"
	}
	printReport(t, map[string]string{"TestGceInstanceValidate": result})
}

// ── Negative tests — one per validation block ─────────────────────────────────

// TestGceInstanceRejectsInvalidEnvironment expects plan to fail when environment is invalid.
func TestGceInstanceRejectsInvalidEnvironment(t *testing.T) {
	t.Parallel()

	vars := validVars()
	vars["environment"] = "production"
	opts := tofuOptions(t, vars)

	terraform.Init(t, opts)
	_, err := terraform.InitAndPlanE(t, opts)

	result := "PASS"
	if err == nil {
		result = "FAIL"
		t.Error("expected plan to fail for environment='production', but it succeeded")
	}
	printReport(t, map[string]string{"TestGceInstanceRejectsInvalidEnvironment": result})
}

// TestGceInstanceRejectsInvalidNamePrefix expects plan to fail when name_prefix starts with a digit.
func TestGceInstanceRejectsInvalidNamePrefix(t *testing.T) {
	t.Parallel()

	vars := validVars()
	vars["name_prefix"] = "1bad"
	opts := tofuOptions(t, vars)

	terraform.Init(t, opts)
	_, err := terraform.InitAndPlanE(t, opts)

	result := "PASS"
	if err == nil {
		result = "FAIL"
		t.Error("expected plan to fail for name_prefix='1bad', but it succeeded")
	}
	printReport(t, map[string]string{"TestGceInstanceRejectsInvalidNamePrefix": result})
}

// TestGceInstanceRejectsInvalidZone expects plan to fail when zone has spaces.
func TestGceInstanceRejectsInvalidZone(t *testing.T) {
	t.Parallel()

	vars := validVars()
	vars["instances"] = []map[string]interface{}{
		{
			"name":         "bastion",
			"machine_type": "e2-micro",
			"zone":         "europe west1 b",
			"boot_image":   "ubuntu-os-cloud/ubuntu-2404-lts-amd64",
			"network_interfaces": []map[string]interface{}{validNic()},
		},
	}
	opts := tofuOptions(t, vars)

	terraform.Init(t, opts)
	_, err := terraform.InitAndPlanE(t, opts)

	result := "PASS"
	if err == nil {
		result = "FAIL"
		t.Error("expected plan to fail for zone with spaces, but it succeeded")
	}
	printReport(t, map[string]string{"TestGceInstanceRejectsInvalidZone": result})
}

// TestGceInstanceRejectsEmptyMachineType expects plan to fail when machine_type is empty.
func TestGceInstanceRejectsEmptyMachineType(t *testing.T) {
	t.Parallel()

	vars := validVars()
	vars["instances"] = []map[string]interface{}{
		{
			"name":         "bastion",
			"machine_type": "",
			"zone":         "europe-west1-b",
			"boot_image":   "ubuntu-os-cloud/ubuntu-2404-lts-amd64",
			"network_interfaces": []map[string]interface{}{validNic()},
		},
	}
	opts := tofuOptions(t, vars)

	terraform.Init(t, opts)
	_, err := terraform.InitAndPlanE(t, opts)

	result := "PASS"
	if err == nil {
		result = "FAIL"
		t.Error("expected plan to fail for empty machine_type, but it succeeded")
	}
	printReport(t, map[string]string{"TestGceInstanceRejectsEmptyMachineType": result})
}

// TestGceInstanceRejectsInvalidBootDiskType expects plan to fail for an unsupported disk type.
func TestGceInstanceRejectsInvalidBootDiskType(t *testing.T) {
	t.Parallel()

	vars := validVars()
	vars["instances"] = []map[string]interface{}{
		{
			"name":             "bastion",
			"machine_type":     "e2-micro",
			"zone":             "europe-west1-b",
			"boot_image":       "ubuntu-os-cloud/ubuntu-2404-lts-amd64",
			"boot_disk_type":   "pd-extreme",
			"network_interfaces": []map[string]interface{}{validNic()},
		},
	}
	opts := tofuOptions(t, vars)

	terraform.Init(t, opts)
	_, err := terraform.InitAndPlanE(t, opts)

	result := "PASS"
	if err == nil {
		result = "FAIL"
		t.Error("expected plan to fail for boot_disk_type='pd-extreme', but it succeeded")
	}
	printReport(t, map[string]string{"TestGceInstanceRejectsInvalidBootDiskType": result})
}

// TestGceInstanceRejectsEmptyNetworkInterfaces expects plan to fail when network_interfaces is empty.
func TestGceInstanceRejectsEmptyNetworkInterfaces(t *testing.T) {
	t.Parallel()

	vars := validVars()
	vars["instances"] = []map[string]interface{}{
		{
			"name":               "bastion",
			"machine_type":       "e2-micro",
			"zone":               "europe-west1-b",
			"boot_image":         "ubuntu-os-cloud/ubuntu-2404-lts-amd64",
			"network_interfaces": []map[string]interface{}{},
		},
	}
	opts := tofuOptions(t, vars)

	terraform.Init(t, opts)
	_, err := terraform.InitAndPlanE(t, opts)

	result := "PASS"
	if err == nil {
		result = "FAIL"
		t.Error("expected plan to fail for empty network_interfaces, but it succeeded")
	}
	printReport(t, map[string]string{"TestGceInstanceRejectsEmptyNetworkInterfaces": result})
}

// TestGceInstanceRejectsInvalidSubnetworkSelfLink expects plan to fail for a malformed self-link.
func TestGceInstanceRejectsInvalidSubnetworkSelfLink(t *testing.T) {
	t.Parallel()

	vars := validVars()
	vars["instances"] = []map[string]interface{}{
		{
			"name":         "bastion",
			"machine_type": "e2-micro",
			"zone":         "europe-west1-b",
			"boot_image":   "ubuntu-os-cloud/ubuntu-2404-lts-amd64",
			"network_interfaces": []map[string]interface{}{
				{
					"subnetwork":         "not-a-self-link",
					"network_ip":         nil,
					"assign_external_ip": false,
					"external_ip":        nil,
				},
			},
		},
	}
	opts := tofuOptions(t, vars)

	terraform.Init(t, opts)
	_, err := terraform.InitAndPlanE(t, opts)

	result := "PASS"
	if err == nil {
		result = "FAIL"
		t.Error("expected plan to fail for invalid subnetwork self-link, but it succeeded")
	}
	printReport(t, map[string]string{"TestGceInstanceRejectsInvalidSubnetworkSelfLink": result})
}

// ── OpenTofu binary enforcement ───────────────────────────────────────────────

// TestNoTerraformBinary confirms that no .tf file references the 'terraform' binary,
// enforcing the OpenTofu-only rule (D-INFRA-01).
func TestNoTerraformBinary(t *testing.T) {
	mod := moduleDir(t)
	tfFiles, err := filepath.Glob(filepath.Join(mod, "*.tf"))
	require.NoError(t, err, "failed to glob *.tf files")
	require.NotEmpty(t, tfFiles, "expected at least one .tf file in module root")

	result := "PASS"
	for _, f := range tfFiles {
		content, readErr := os.ReadFile(f)
		require.NoError(t, readErr, "failed to read %s", f)

		// Scan each line; flag any occurrence of a bare 'terraform' binary invocation.
		// Legitimate HCL uses the 'terraform' block keyword — we skip those.
		for i, line := range strings.Split(string(content), "\n") {
			trimmed := strings.TrimSpace(line)
			// Allow the HCL block keyword and comments.
			if strings.HasPrefix(trimmed, "terraform {") ||
				strings.HasPrefix(trimmed, "#") ||
				strings.HasPrefix(trimmed, "//") {
				continue
			}
			// Flag references to the binary name in strings or shell invocations.
			if strings.Contains(line, `"terraform"`) || strings.Contains(line, "`terraform`") {
				result = "FAIL"
				t.Errorf("%s line %d: found reference to 'terraform' binary — use 'tofu' (D-INFRA-01): %s",
					filepath.Base(f), i+1, trimmed)
			}
		}
	}

	printReport(t, map[string]string{"TestNoTerraformBinary": result})
}
