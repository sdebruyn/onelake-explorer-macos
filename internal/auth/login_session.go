package auth

import (
	"errors"
	"fmt"
	"sync"

	"github.com/AzureAD/microsoft-authentication-library-for-go/apps/public"
)

// ErrSessionNotFound is returned by [LoginSessionStore.Claim] when no
// session with the given ID exists (already claimed, never started, or
// the daemon was restarted).
var ErrSessionNotFound = errors.New("auth: login session not found")

// LoginSessionResult is the outcome of one completed MSAL interactive
// login, delivered through [LoginSession.ResultCh].
type LoginSessionResult struct {
	Account    Account
	MSALAcct   public.Account
	CacheBytes []byte
	Err        error
}

// LoginSession is an in-flight two-phase interactive login. The host
// app receives an AuthURL from the daemon via auth.login.start, opens
// the browser, and then calls auth.login.complete to wait for the OAuth
// redirect to arrive at MSAL's localhost listener.
//
// The lifecycle is single-use: once ResultCh delivers a value the session
// is done and must not be reused.
type LoginSession struct {
	// ID is the opaque session token the client passes back in
	// auth.login.complete to identify this particular login attempt.
	ID string

	// AuthURL is the Microsoft Entra authorization URL that the host
	// app must open in the system browser.
	AuthURL string

	// ResultCh receives exactly one value when MSAL completes or fails
	// the OAuth exchange. The channel has a buffer of 1 so the MSAL
	// goroutine never blocks if the client disconnects before calling
	// auth.login.complete.
	ResultCh chan LoginSessionResult
}

// LoginSessionStore is a concurrency-safe map of pending login sessions
// keyed by session ID. It is owned by [Handlers] and lives for the
// daemon's lifetime.
//
// The zero value is not usable; construct with [NewLoginSessionStore].
type LoginSessionStore struct {
	mu       sync.Mutex
	sessions map[string]*LoginSession
}

// NewLoginSessionStore returns an empty, ready-to-use store.
func NewLoginSessionStore() *LoginSessionStore {
	return &LoginSessionStore{
		sessions: make(map[string]*LoginSession),
	}
}

// Register inserts sess into the store keyed by sess.ID. It panics if
// sess or sess.ID is zero — both are programming errors.
func (s *LoginSessionStore) Register(sess *LoginSession) {
	if sess == nil || sess.ID == "" {
		panic("auth: LoginSessionStore.Register: nil or empty session")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sessions[sess.ID] = sess
}

// Claim removes the session with the given id from the store and returns
// it. If no session with that id exists, [ErrSessionNotFound] is
// returned. Claim is the only way to obtain a session for consumption;
// calling it twice for the same id always returns an error on the second
// call, preventing replay.
func (s *LoginSessionStore) Claim(id string) (*LoginSession, error) {
	if id == "" {
		return nil, fmt.Errorf("auth: session id is required")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	sess, ok := s.sessions[id]
	if !ok {
		return nil, fmt.Errorf("%w: %q", ErrSessionNotFound, id)
	}
	delete(s.sessions, id)
	return sess, nil
}
