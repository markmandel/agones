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

package wasm

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"

	pluginsv1 "agones.dev/agones/pkg/apis/plugins/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/tetratelabs/wazero"
)

// compilationCache is shared by every Cache in these tests, so the example plugin is only compiled
// once, rather than every time a test loads it.
var compilationCache = wazero.NewCompilationCache()

// newCache returns a Cache that shares compiled code with every other Cache in these tests.
func newCache(t *testing.T, size int) *Cache {
	t.Helper()

	c, err := NewCache(size)
	require.NoError(t, err)
	c.runtimeConfig = wazero.NewRuntimeConfig().WithCompilationCache(compilationCache)
	return c
}

const gameServerJSON = `{"metadata":{"name":"gs"},"status":{"state":"Allocated","lists":{"freeSessions":{"capacity":3,"values":["session-1","session-2","session-3"]}}}}`

// wasmServer serves the allocation-wasm example plugin, and counts how many times it has been requested.
func wasmServer(t *testing.T) (*httptest.Server, *atomic.Int32, string) {
	t.Helper()

	dir, err := filepath.Abs(filepath.Join("..", "..", "..", "examples", "allocation-wasm"))
	require.NoError(t, err)
	b, err := os.ReadFile(filepath.Join(dir, "plugin.wasm"))
	require.NoError(t, err, "wasm plugin not found in %s", dir)
	sum := sha256.Sum256(b)

	requests := &atomic.Int32{}
	fs := http.FileServer(http.Dir(dir))
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		fs.ServeHTTP(w, r)
	}))
	t.Cleanup(srv.Close)

	return srv, requests, hex.EncodeToString(sum[:])
}

func wasmPolicy(url, function string) *pluginsv1.WasmPolicy {
	return &pluginsv1.WasmPolicy{
		Function: function,
		Config:   map[string]string{"list": "freeSessions"},
		From:     pluginsv1.WasmFrom{URL: &pluginsv1.URLConfiguration{URL: &url}},
	}
}

// annotations returns the annotations of the GameServer JSON that is returned from the plugin.
func annotations(t *testing.T, output []byte) map[string]string {
	t.Helper()

	gs := struct {
		Metadata struct {
			Annotations map[string]string `json:"annotations"`
		} `json:"metadata"`
	}{}
	require.NoError(t, json.Unmarshal(output, &gs))
	return gs.Metadata.Annotations
}

func TestCacheCall(t *testing.T) {
	t.Parallel()

	srv, requests, hash := wasmServer(t)
	url := srv.URL + "/plugin.wasm"
	ctx := context.Background()

	c := newCache(t, 10)

	output, err := c.Call(ctx, wasmPolicy(url, "allocate"), []byte(gameServerJSON))
	require.NoError(t, err)
	assert.Equal(t, map[string]string{"session": "session-1"}, annotations(t, output))
	assert.Equal(t, 1, c.Len())

	// config is applied on each call, and the module is only downloaded the once.
	wp := wasmPolicy(url, "allocate")
	wp.Config["annotation"] = "other"
	output, err = c.Call(ctx, wp, []byte(gameServerJSON))
	require.NoError(t, err)
	assert.Equal(t, map[string]string{"other": "session-1"}, annotations(t, output))

	output, err = c.Call(ctx, wasmPolicy(url, "allocateNone"), []byte(gameServerJSON))
	require.NoError(t, err)
	assert.Empty(t, annotations(t, output))
	assert.Contains(t, string(output), `"values":["session-1","session-2","session-3"]`)
	assert.Equal(t, 1, c.Len())
	assert.Equal(t, int32(1), requests.Load())

	// a hash is a different module in the cache.
	wp = wasmPolicy(url, "allocate")
	wp.Hash = hash
	_, err = c.Call(ctx, wp, []byte(gameServerJSON))
	require.NoError(t, err)
	assert.Equal(t, 2, c.Len())
	assert.Equal(t, int32(2), requests.Load())
}

func TestCacheCallErrors(t *testing.T) {
	t.Parallel()

	srv, _, hash := wasmServer(t)
	url := srv.URL + "/plugin.wasm"
	ctx := context.Background()

	c := newCache(t, 10)

	_, err := NewCache(0)
	require.Error(t, err)

	_, err = c.Call(ctx, nil, []byte(gameServerJSON))
	require.ErrorContains(t, err, "wasm policy does not have a module to load")

	_, err = c.Call(ctx, wasmPolicy(srv.URL+"/missing.wasm", "allocate"), []byte(gameServerJSON))
	require.ErrorContains(t, err, "bad status code 404")

	_, err = c.Call(ctx, wasmPolicy(srv.URL+"/main.go", "allocate"), []byte(gameServerJSON))
	require.ErrorContains(t, err, "failed to compile wasm module")

	wp := wasmPolicy(url, "allocate")
	wp.Hash = "00" + hash[2:]
	_, err = c.Call(ctx, wp, []byte(gameServerJSON))
	require.ErrorContains(t, err, "failed to compile wasm module")
	assert.Equal(t, 0, c.Len())

	_, err = c.Call(ctx, wasmPolicy(url, "missing"), []byte(gameServerJSON))
	require.ErrorContains(t, err, `wasm function "missing" does not exist`)

	// the plugin returns an error, as the list is not there.
	wp = wasmPolicy(url, "allocate")
	wp.Config["list"] = "missing"
	_, err = c.Call(ctx, wp, []byte(gameServerJSON))
	require.ErrorContains(t, err, `failed to call wasm function "allocate"`)
}

func TestCacheEviction(t *testing.T) {
	t.Parallel()

	srv, requests, _ := wasmServer(t)
	first := srv.URL + "/plugin.wasm"
	second := srv.URL + "/plugin.wasm?second"
	ctx := context.Background()

	c := newCache(t, 1)

	for i, url := range []string{first, second, first} {
		output, err := c.Call(ctx, wasmPolicy(url, "allocate"), []byte(gameServerJSON))
		require.NoError(t, err)
		assert.Equal(t, map[string]string{"session": "session-1"}, annotations(t, output))
		assert.Equal(t, 1, c.Len())
		assert.Equal(t, int32(i+1), requests.Load())
	}
}

func TestCacheConcurrentCalls(t *testing.T) {
	t.Parallel()

	srv, _, _ := wasmServer(t)
	urls := []string{srv.URL + "/plugin.wasm", srv.URL + "/plugin.wasm?second"}
	ctx := context.Background()

	// only room for one module, so modules are evicted while they are being called.
	c := newCache(t, 1)

	wg := sync.WaitGroup{}
	for i := range 8 {
		wg.Go(func() {
			output, err := c.Call(ctx, wasmPolicy(urls[i%len(urls)], "allocate"), []byte(gameServerJSON))
			if assert.NoError(t, err) {
				assert.Contains(t, string(output), `"session":"session-1"`)
			}
		})
	}
	wg.Wait()
}
