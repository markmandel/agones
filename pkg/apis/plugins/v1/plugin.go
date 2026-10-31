// Copyright Contributors to Agones a Series of LF Projects, LLC.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package v1

import (
	"crypto/x509"
	"net/url"

	"agones.dev/agones/pkg/util/runtime"
	admissionregistrationv1 "k8s.io/api/admissionregistration/v1"
	"k8s.io/apimachinery/pkg/util/validation/field"
)

// URLConfiguration is a generic configuration for any integration with an external URL or
// cluster provided service. For example, it can be used to configure a webhook or Wasm module
type URLConfiguration admissionregistrationv1.WebhookClientConfig

// ValidateURLConfiguration validates the URLConfiguration settings to make sure either a URL is set or
// a Service is set, but not both. Also checks that the CABundle is valid if HTTPS is used.
func (w *URLConfiguration) ValidateURLConfiguration(fldPath *field.Path) field.ErrorList {
	var allErrs field.ErrorList
	if w == nil {
		return append(allErrs, field.Required(fldPath, "webhook policy config params are missing"))
	}
	if w.Service == nil && w.URL == nil {
		allErrs = append(allErrs, field.Required(fldPath, "url should be provided"))
	}
	if w.Service != nil && w.URL != nil {
		allErrs = append(allErrs, field.Duplicate(fldPath.Child("url"), "service and url cannot be used simultaneously"))
	}
	if w.CABundle != nil {
		rootCAs := x509.NewCertPool()
		// Check that CABundle provided is correctly encoded certificate
		if ok := rootCAs.AppendCertsFromPEM(w.CABundle); !ok {
			allErrs = append(allErrs, field.Invalid(fldPath.Child("caBundle"), w.CABundle, "CA Bundle is not valid"))
		}
	}
	if w.URL != nil {
		_, err := url.Parse(*w.URL)
		if err != nil {
			allErrs = append(allErrs, field.Invalid(fldPath.Child("url"), *w.URL, "url is not valid"))
		}
	}
	return allErrs
}

// WasmFrom defines the source of the Wasm module
type WasmFrom struct {
	// URL is the URL of the Wasm module.
	URL *URLConfiguration `json:"url"`
}

// WasmPolicy contains the configuration for a WebAssembly module that runs as a plugin to Agones.
type WasmPolicy struct {
	// Function is the exported function to call in the wasm module. The default depends on where the plugin is used.
	// +optional
	Function string `json:"function,omitempty"`
	// Config values to pass to the wasm program on startup
	// +optional
	Config map[string]string `json:"config,omitempty"`
	// WasmFrom defines the source of the Wasm module
	From WasmFrom `json:"from"`
	// Hash of the Wasm module, used to verify the integrity of the module
	// +optional
	Hash string `json:"hash,omitempty"`
}

// ValidateWasmPolicy validates the FleetAutoscaler Wasm policy settings
func (w *WasmPolicy) ValidateWasmPolicy(fldPath *field.Path) field.ErrorList {
	var allErrs field.ErrorList
	if w == nil {
		return append(allErrs, field.Required(fldPath, "wasm policy config params are missing"))
	}

	if !runtime.FeatureEnabled(runtime.FeatureWasmAutoscaler) {
		return append(allErrs, field.Forbidden(fldPath, "feature WasmAutoscaler must be enabled"))
	}

	fldPath = fldPath.Child("from")
	if w.From.URL == nil {
		return append(allErrs, field.Required(fldPath, "wasm from configuration is missing"))
	}
	allErrs = w.From.URL.ValidateURLConfiguration(fldPath.Child("url"))

	return allErrs
}
