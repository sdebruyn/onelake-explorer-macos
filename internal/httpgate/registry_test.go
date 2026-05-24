package httpgate

import (
	"testing"
	"time"
)

// TestRegistry_GateLazyCreate verifies that calling Gate on an unknown
// host creates a gate with the registry defaults.
func TestRegistry_GateLazyCreate(t *testing.T) {
	r := NewRegistry(Defaults{Concurrency: 3, QPS: 4, Burst: 5})
	g := r.Gate("unknown.example.com")
	if g == nil {
		t.Fatal("Gate returned nil")
	}
	st := g.State()
	if st.Concurrency != 3 || st.Burst != 5 || st.QPS != 4 {
		t.Errorf("defaults not applied: %+v", st)
	}
	// Same host returns the same gate.
	if other := r.Gate("unknown.example.com"); other != g {
		t.Error("Gate returned a different instance for the same host")
	}
}

// TestRegistry_RegisterOverrides verifies that an explicit Register
// wins over the defaults.
func TestRegistry_RegisterOverrides(t *testing.T) {
	r := NewRegistry(Defaults{Concurrency: 3, QPS: 4, Burst: 5})
	r.Register("api.fabric.microsoft.com", 8, 2, 4)
	st := r.Gate("api.fabric.microsoft.com").State()
	if st.Concurrency != 8 || st.QPS != 2 || st.Burst != 4 {
		t.Errorf("explicit Register lost: %+v", st)
	}
}

// TestRegistry_States returns one entry per gate, sorted.
func TestRegistry_States(t *testing.T) {
	r := NewRegistry(Defaults{Concurrency: 1, QPS: 1, Burst: 1})
	r.Register("b.example.com", 1, 1, 1)
	r.Register("a.example.com", 1, 1, 1)
	r.Gate("c.example.com") // lazy-create

	states := r.States()
	if len(states) != 3 {
		t.Fatalf("got %d states, want 3", len(states))
	}
	want := []string{"a.example.com", "b.example.com", "c.example.com"}
	for i, s := range states {
		if s.Host != want[i] {
			t.Errorf("states[%d].Host = %q, want %q", i, s.Host, want[i])
		}
	}
}

// TestDefaultRegistry verifies the convenience constructor pre-
// registers both production hosts.
func TestDefaultRegistry(t *testing.T) {
	r := DefaultRegistry()
	for _, host := range []string{HostFabric, HostOneLake} {
		st := r.Gate(host).State()
		if st.Host != host {
			t.Errorf("missing gate for %s", host)
		}
	}
	fab := r.Gate(HostFabric).State()
	if fab.Concurrency != FabricConcurrency || fab.Burst != FabricBurst {
		t.Errorf("fabric budget not applied: %+v", fab)
	}
	one := r.Gate(HostOneLake).State()
	if one.Concurrency != OneLakeConcurrency || one.Burst != OneLakeBurst {
		t.Errorf("onelake budget not applied: %+v", one)
	}
}

// TestState_String renders the human-friendly summary.
func TestState_String(t *testing.T) {
	s := State{
		Host:        "api.fabric.microsoft.com",
		Inflight:    3,
		Concurrency: 8,
		Available:   2,
		Burst:       4,
		QPS:         2,
	}
	got := s.String()
	want := "api.fabric.microsoft.com inflight=3/8 tokens=2/4 paused: no"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}

	s.PauseUntil = time.Now().Add(23 * time.Second)
	got = s.String()
	if !contains(got, "paused: for ") {
		t.Errorf("paused branch missing in %q", got)
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
