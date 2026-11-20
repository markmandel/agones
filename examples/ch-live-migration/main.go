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

// Minimal PID 1 for Cloud Hypervisor live-migration tests.
// Mounts the virtio-fs share, then runs a UDP echo that reports in-memory
// state (boot ID, tick counter, request counter) plus a file read from the
// share, so a client can tell a live migration apart from a reboot.
package main

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net"
	"os"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

func main() {
	for _, m := range []struct{ src, dst, fstype string }{
		{"proc", "/proc", "proc"},
		{"sysfs", "/sys", "sysfs"},
		{"devtmpfs", "/dev", "devtmpfs"},
	} {
		_ = os.MkdirAll(m.dst, 0o755)
		if err := syscall.Mount(m.src, m.dst, m.fstype, 0, ""); err != nil {
			fmt.Printf("mount %s: %v\n", m.dst, err)
		}
	}
	_ = os.MkdirAll("/mnt", 0o755)
	if err := syscall.Mount("share", "/mnt", "virtiofs", 0, ""); err != nil {
		fmt.Printf("mount virtiofs: %v\n", err)
	}

	b := make([]byte, 4)
	_, _ = rand.Read(b)
	bootID := hex.EncodeToString(b)
	start := time.Now()

	var ticks, reqs atomic.Int64
	go func() {
		for range time.Tick(100 * time.Millisecond) {
			ticks.Add(1)
		}
	}()

	conn, err := net.ListenUDP("udp", &net.UDPAddr{Port: 7777})
	if err != nil {
		fmt.Printf("listen: %v\n", err)
		select {}
	}
	fmt.Printf("guest ready boot=%s\n", bootID)
	buf := make([]byte, 1500)
	for {
		n, addr, err := conn.ReadFromUDP(buf)
		if err != nil {
			continue
		}
		file := "ERR"
		if data, err := os.ReadFile("/mnt/hello.txt"); err == nil {
			file = strings.TrimSpace(string(data))
		} else {
			file = "ERR:" + err.Error()
		}
		reply := fmt.Sprintf("boot=%s req=%d ticks=%d up=%.1fs file=%q msg=%s",
			bootID, reqs.Add(1), ticks.Load(), time.Since(start).Seconds(), file,
			strings.TrimSpace(string(buf[:n])))
		_, _ = conn.WriteToUDP([]byte(reply), addr)
	}
}
