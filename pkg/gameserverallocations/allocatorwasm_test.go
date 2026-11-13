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

package gameserverallocations

import (
	"context"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	allocationv1 "agones.dev/agones/pkg/apis/allocation/v1"
	pluginsv1 "agones.dev/agones/pkg/apis/plugins/v1"
	agtesting "agones.dev/agones/pkg/testing"
	utilruntime "agones.dev/agones/pkg/util/runtime"
	"agones.dev/agones/pkg/util/wasm"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	k8sruntime "k8s.io/apimachinery/pkg/runtime"
	k8stesting "k8s.io/client-go/testing"
)

const wasmListName = "freeSessions"

var (
	// wasmURL is where the allocation-wasm example plugin is served from, for every test.
	wasmURL     string
	wasmURLOnce sync.Once
	// wasmCache is shared by every test, so the plugin is only compiled once.
	wasmCache = func() *wasm.Cache {
		c, err := wasm.NewCache(defaultTestWasmCacheSize)
		utilruntime.Must(err)
		return c
	}()
)

// wasmFixtures serves the allocation-wasm example plugin, and returns a function that creates
// a GameServerAllocation that calls a given function on that plugin.
func wasmFixtures(t *testing.T) func(function string) *allocationv1.GameServerAllocation {
	t.Helper()

	wasmURLOnce.Do(func() {
		dir, err := filepath.Abs(filepath.Join("..", "..", "examples", "allocation-wasm"))
		utilruntime.Must(err)
		// not closed, as it is shared by every test in the package.
		srv := httptest.NewServer(http.FileServer(http.Dir(dir)))
		wasmURL = srv.URL + "/plugin.wasm"

		// compile the plugin up front, as it is slow, and should not count towards any test's timeouts.
		_, err = wasmCache.Call(context.Background(), &pluginsv1.WasmPolicy{
			Function: "allocateNone",
			From:     pluginsv1.WasmFrom{URL: &pluginsv1.URLConfiguration{URL: &wasmURL}},
		}, []byte("{}"))
		utilruntime.Must(err)
	})
	url := wasmURL

	return func(function string) *allocationv1.GameServerAllocation {
		gsa := &allocationv1.GameServerAllocation{
			ObjectMeta: metav1.ObjectMeta{Name: "gsa-1", Namespace: defaultNs},
			Spec: allocationv1.GameServerAllocationSpec{
				Wasm: &pluginsv1.WasmPolicy{
					Function: function,
					Config:   map[string]string{"list": wasmListName},
					From:     pluginsv1.WasmFrom{URL: &pluginsv1.URLConfiguration{URL: &url}},
				},
			},
		}
		gsa.ApplyDefaults()
		gsa.Converter()
		return gsa
	}
}

func wasmGameServer() *agonesv1.GameServer {
	return &agonesv1.GameServer{
		ObjectMeta: metav1.ObjectMeta{Name: "gs1", Namespace: defaultNs, UID: "1234", ResourceVersion: "5"},
		Status: agonesv1.GameServerStatus{
			State: agonesv1.GameServerStateReady,
			Lists: map[string]agonesv1.ListStatus{
				wasmListName: {Capacity: 3, Values: []string{"session-1", "session-2", "session-3"}},
			},
		},
	}
}

func TestAllocatorApplyAllocationToGameServerWasm(t *testing.T) {
	t.Parallel()

	utilruntime.FeatureTestMutex.Lock()
	defer utilruntime.FeatureTestMutex.Unlock()
	require.NoError(t, utilruntime.ParseFeatures(string(utilruntime.FeatureWasmAllocation)+"=true"))

	gsa := wasmFixtures(t)
	ctx := context.Background()
	a, m := newFakeAllocator()
	a.wasmCache = wasmCache

	updates := atomic.Int32{}
	m.AgonesClient.AddReactor("update", "gameservers", func(action k8stesting.Action) (bool, k8sruntime.Object, error) {
		updates.Add(1)
		ua := action.(k8stesting.UpdateAction)
		gs := ua.GetObject().(*agonesv1.GameServer)
		return true, gs, nil
	})

	t.Run("session is allocated from the list", func(t *testing.T) {
		gs, err := a.applyAllocationToGameServer(ctx, allocationv1.MetaPatch{Labels: map[string]string{"foo": "bar"}}, wasmGameServer(), gsa(""))
		require.NoError(t, err)
		assert.Equal(t, agonesv1.GameServerStateAllocated, gs.Status.State)
		assert.Equal(t, "session-1", gs.ObjectMeta.Annotations["session"])
		assert.Equal(t, []string{"session-2", "session-3"}, gs.Status.Lists[wasmListName].Values)
		assert.Equal(t, int64(3), gs.Status.Lists[wasmListName].Capacity)
		assert.Equal(t, "bar", gs.ObjectMeta.Labels["foo"])
		assert.NotEmpty(t, gs.ObjectMeta.Annotations[LastAllocatedAnnotationKey])
	})

	t.Run("plugin sees the result of list actions", func(t *testing.T) {
		g := gsa("")
		g.Spec.Lists = map[string]allocationv1.ListAction{wasmListName: {DeleteValues: []string{"session-1"}}}
		gs, err := a.applyAllocationToGameServer(ctx, allocationv1.MetaPatch{}, wasmGameServer(), g)
		require.NoError(t, err)
		assert.Equal(t, "session-2", gs.ObjectMeta.Annotations["session"])
		assert.Equal(t, []string{"session-3"}, gs.Status.Lists[wasmListName].Values)
	})

	t.Run("identity and state cannot be changed", func(t *testing.T) {
		original := wasmGameServer()
		gs, err := a.applyAllocationToGameServer(ctx, allocationv1.MetaPatch{}, wasmGameServer(), gsa("allocateIdentity"))
		require.NoError(t, err)
		assert.Equal(t, original.ObjectMeta.Name, gs.ObjectMeta.Name)
		assert.Equal(t, original.ObjectMeta.Namespace, gs.ObjectMeta.Namespace)
		assert.Equal(t, original.ObjectMeta.UID, gs.ObjectMeta.UID)
		assert.Equal(t, original.ObjectMeta.ResourceVersion, gs.ObjectMeta.ResourceVersion)
		assert.Equal(t, agonesv1.GameServerStateAllocated, gs.Status.State)
		assert.NotEmpty(t, gs.ObjectMeta.Annotations[LastAllocatedAnnotationKey])
		// but everything else can.
		assert.Equal(t, "true", gs.ObjectMeta.Labels["changed"])
	})

	t.Run("unchanged GameServer is returned exactly", func(t *testing.T) {
		// a full GameServer, as it would be in a Fleet, so any field the plugin's model of the
		// GameServer is missing would be lost.
		_, gsList := defaultFixtures(1)
		gs := gsList[0].DeepCopy()
		gs.ObjectMeta.UID = "1234"
		gs.ObjectMeta.ResourceVersion = "5"
		gs.ObjectMeta.Generation = 2
		gs.ObjectMeta.CreationTimestamp = metav1.NewTime(time.Now().Truncate(time.Second))
		gs.ObjectMeta.Finalizers = []string{"agones.dev"}
		gs.ObjectMeta.Labels["foo"] = "bar"
		gs.ObjectMeta.Annotations = map[string]string{LastAllocatedAnnotationKey: "now", "bar": "foo"}
		reservedUntil := metav1.NewTime(time.Now().Add(time.Hour).Truncate(time.Second))
		gs.Status = agonesv1.GameServerStatus{
			State:         agonesv1.GameServerStateAllocated,
			Ports:         []agonesv1.GameServerStatusPort{{Name: "default", Port: 7777}},
			Address:       "10.0.0.1",
			Addresses:     []corev1.NodeAddress{{Type: corev1.NodeExternalIP, Address: "10.0.0.1"}},
			NodeName:      "node1",
			ReservedUntil: &reservedUntil,
			Counters:      map[string]agonesv1.CounterStatus{"rooms": {Count: 1, Capacity: 10}},
			Lists:         wasmGameServer().Status.Lists,
			Eviction:      &agonesv1.Eviction{Safe: agonesv1.EvictionSafeOnUpgrade},
		}
		gs.Spec.Ports = []agonesv1.GameServerPort{{Name: "default", PortPolicy: agonesv1.Dynamic, ContainerPort: 7654, HostPort: 7777, Protocol: corev1.ProtocolUDP}}
		require.NotEmpty(t, gs.ObjectMeta.OwnerReferences)

		result, err := a.applyWasmPolicy(ctx, gsa("allocateNone").Spec.Wasm, gs.DeepCopy())
		require.NoError(t, err)
		assert.Equal(t, gs, result)
	})

	t.Run("plugin failure does not update the GameServer", func(t *testing.T) {
		for _, function := range []string{"allocateInvalid", "missing"} {
			before := updates.Load()
			gs, err := a.applyAllocationToGameServer(ctx, allocationv1.MetaPatch{Labels: map[string]string{"foo": "bar"}}, wasmGameServer(), gsa(function))
			require.ErrorIs(t, err, ErrWasmPlugin)
			// the GameServer is returned as it was.
			assert.Equal(t, wasmGameServer(), gs)
			assert.Equal(t, before, updates.Load())
		}
	})

	t.Run("feature gate is disabled", func(t *testing.T) {
		require.NoError(t, utilruntime.ParseFeatures(string(utilruntime.FeatureWasmAllocation)+"=false"))
		defer func() {
			require.NoError(t, utilruntime.ParseFeatures(string(utilruntime.FeatureWasmAllocation)+"=true"))
		}()

		_, err := a.applyAllocationToGameServer(ctx, allocationv1.MetaPatch{}, wasmGameServer(), gsa(""))
		require.ErrorIs(t, err, ErrWasmPlugin)
	})
}

func TestAllocatorAllocateWasm(t *testing.T) {
	t.Parallel()

	utilruntime.FeatureTestMutex.Lock()
	defer utilruntime.FeatureTestMutex.Unlock()
	require.NoError(t, utilruntime.ParseFeatures(string(utilruntime.FeatureWasmAllocation)+"=true"))

	gsa := wasmFixtures(t)
	a, m := newFakeAllocator()
	a.wasmCache = wasmCache

	gsLen := 2
	_, gsList := defaultFixtures(gsLen)
	for i := range gsList {
		gsList[i].Status.Lists = wasmGameServer().Status.Lists
	}
	m.AgonesClient.AddReactor("list", "gameservers", func(_ k8stesting.Action) (bool, k8sruntime.Object, error) {
		return true, &agonesv1.GameServerList{Items: gsList}, nil
	})
	updates := atomic.Int32{}
	m.AgonesClient.AddReactor("update", "gameservers", func(action k8stesting.Action) (bool, k8sruntime.Object, error) {
		updates.Add(1)
		ua := action.(k8stesting.UpdateAction)
		gs := ua.GetObject().(*agonesv1.GameServer)
		return true, gs, nil
	})

	ctx, cancel := agtesting.StartInformers(m, a.allocationCache.gameServerSynced)
	defer cancel()

	require.NoError(t, a.Run(ctx))
	require.Eventuallyf(t, func() bool {
		return a.allocationCache.cache.Len() == gsLen
	}, 10*time.Second, time.Second, "should be %d items in the cache", gsLen)

	// a failing plugin fails the allocation, and the GameServer stays available.
	g := gsa("allocateInvalid")
	require.Empty(t, g.Validate())
	result, err := a.Allocate(ctx, g)
	require.Error(t, err)
	assert.Nil(t, result)
	assert.Equal(t, codes.Internal, status.Code(err))
	assert.Contains(t, err.Error(), ErrWasmPlugin.Error())
	assert.Equal(t, int32(0), updates.Load())
	require.Eventuallyf(t, func() bool {
		return a.allocationCache.cache.Len() == gsLen
	}, 10*time.Second, time.Second, "should be %d items in the cache", gsLen)

	// make sure we aren't in the same batch!
	time.Sleep(2 * a.batchWaitTime)

	g = gsa("")
	require.Empty(t, g.Validate())
	assert.Equal(t, allocationv1.DefaultWasmFunction, g.Spec.Wasm.Function)
	result, err = a.Allocate(ctx, g)
	require.NoError(t, err)
	allocated, ok := result.(*allocationv1.GameServerAllocation)
	require.True(t, ok)
	assert.Equal(t, allocationv1.GameServerAllocationAllocated, allocated.Status.State)
	assert.Equal(t, "session-1", allocated.Status.Metadata.Annotations["session"])
	assert.Equal(t, []string{"session-2", "session-3"}, allocated.Status.Lists[wasmListName].Values)
	assert.Equal(t, int32(1), updates.Load())
}
