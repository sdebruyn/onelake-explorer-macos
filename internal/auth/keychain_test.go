package auth

import (
	"bytes"
	"errors"
	"os"
	"testing"
)

func TestMemoryKeychainRoundTrip(t *testing.T) {
	kc := NewMemoryKeychain()

	payload := []byte{0x00, 0x01, 0xff, 0xfe, 'h', 'i'}
	if err := kc.Set("work", payload); err != nil {
		t.Fatalf("set: %v", err)
	}

	got, err := kc.Get("work")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Errorf("got %x, want %x", got, payload)
	}
}

func TestMemoryKeychainGetMissingReturnsNotExist(t *testing.T) {
	kc := NewMemoryKeychain()

	_, err := kc.Get("nope")
	if err == nil {
		t.Fatal("expected error for missing entry")
	}
	if !errors.Is(err, os.ErrNotExist) {
		t.Errorf("err = %v, want errors.Is os.ErrNotExist", err)
	}
}

func TestMemoryKeychainEmptyValueDeletes(t *testing.T) {
	kc := NewMemoryKeychain()
	if err := kc.Set("work", []byte("secret")); err != nil {
		t.Fatalf("set: %v", err)
	}

	for _, empty := range [][]byte{nil, {}} {
		if err := kc.Set("work", empty); err != nil {
			t.Fatalf("set empty: %v", err)
		}
		if _, err := kc.Get("work"); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("after empty set, get = %v, want os.ErrNotExist", err)
		}
		// re-seed for the next iteration
		if err := kc.Set("work", []byte("secret")); err != nil {
			t.Fatalf("re-seed: %v", err)
		}
	}
}

func TestMemoryKeychainDeleteMissingIsNoop(t *testing.T) {
	kc := NewMemoryKeychain()
	if err := kc.Delete("ghost"); err != nil {
		t.Errorf("delete missing: %v", err)
	}
}

func TestMemoryKeychainStoresCopy(t *testing.T) {
	kc := NewMemoryKeychain()
	payload := []byte("original")
	if err := kc.Set("work", payload); err != nil {
		t.Fatalf("set: %v", err)
	}
	// mutate caller's slice; stored entry must be unaffected
	payload[0] = 'X'

	got, err := kc.Get("work")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if !bytes.Equal(got, []byte("original")) {
		t.Errorf("stored entry was mutated: %s", got)
	}

	// mutate returned slice; subsequent Get must still return original
	got[0] = 'Y'
	again, err := kc.Get("work")
	if err != nil {
		t.Fatalf("get again: %v", err)
	}
	if !bytes.Equal(again, []byte("original")) {
		t.Errorf("returned slice aliased internal storage: %s", again)
	}
}
