package main

import (
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const sockBuf = 4 << 20

type udpRelay struct {
	server *net.UDPAddr
	local  *net.UDPConn
	rotate int
	keep   time.Duration

	clientAddr atomic.Pointer[net.UDPAddr]

	mu    sync.Mutex
	cur   *net.UDPConn
	cnt   int
	socks []outSock

	upBytes, downBytes, rotations atomic.Uint64
}

type outSock struct {
	conn    *net.UDPConn
	created time.Time
}

func runRelay(args []string) error {
	fs := flag.NewFlagSet("run", flag.ExitOnError)
	server := fs.String("server", "", "")
	port := fs.Int("port", 2100, "")
	listen := fs.String("listen", "127.0.0.1:18095", "")
	rotate := fs.Int("rotate", 22, "")
	keep := fs.Duration("keep", 8*time.Second, "")
	parent := fs.Int("parent-pid", 0, "")
	stats := fs.Duration("stats", time.Second, "")
	_ = fs.Parse(args)
	if *server == "" {
		return errors.New("--server is required")
	}
	if *rotate < 1 {
		return errors.New("bad value")
	}
	raiseNoFile(8192)

	r, err := newRelay(*server, *port, *listen, *rotate, *keep)
	if err != nil {
		return err
	}
	fmt.Println("READY")

	if *parent > 0 {
		go watchParent(*parent)
	}
	if *stats > 0 {
		go r.statsLoop(*stats)
	}
	return r.uplink()
}

func newRelay(server string, port int, listen string, rotate int, keep time.Duration) (*udpRelay, error) {
	srv, err := net.ResolveUDPAddr("udp4", net.JoinHostPort(server, fmt.Sprint(port)))
	if err != nil {
		return nil, fmt.Errorf("resolve server: %w", err)
	}
	laddr, err := net.ResolveUDPAddr("udp4", listen)
	if err != nil {
		return nil, fmt.Errorf("listen address: %w", err)
	}
	local, err := net.ListenUDP("udp4", laddr)
	if err != nil {
		return nil, fmt.Errorf("bind %s: %w", listen, err)
	}
	_ = local.SetReadBuffer(sockBuf)
	r := &udpRelay{server: srv, local: local, rotate: rotate, keep: keep}
	if err := r.newSock(); err != nil {
		local.Close()
		return nil, err
	}
	go r.gcLoop()
	return r, nil
}

func (r *udpRelay) uplink() error {
	buf := make([]byte, 65535)
	for {
		n, addr, err := r.local.ReadFromUDP(buf)
		if err != nil {
			return fmt.Errorf("local read: %w", err)
		}
		r.clientAddr.Store(addr)
		r.mu.Lock()
		if r.cnt >= r.rotate {
			if err := r.newSockLocked(); err != nil {
				fmt.Fprintln(os.Stderr, "new socket:", err)
			}
		}
		cur := r.cur
		r.cnt++
		r.mu.Unlock()
		if _, err := cur.WriteToUDP(buf[:n], r.server); err == nil {
			r.upBytes.Add(uint64(n))
		}
	}
}

func (r *udpRelay) newSock() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.newSockLocked()
}

func (r *udpRelay) newSockLocked() error {
	r.gcLocked()
	c, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
	if err != nil {
		return err
	}
	_ = c.SetReadBuffer(sockBuf)
	r.socks = append(r.socks, outSock{conn: c, created: time.Now()})
	r.cur = c
	r.cnt = 0
	r.rotations.Add(1)
	go r.downlink(c)
	return nil
}

func (r *udpRelay) downlink(c *net.UDPConn) {
	buf := make([]byte, 65535)
	for {
		n, _, err := c.ReadFromUDP(buf)
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			continue
		}
		if ca := r.clientAddr.Load(); ca != nil {
			if _, err := r.local.WriteToUDP(buf[:n], ca); err == nil {
				r.downBytes.Add(uint64(n))
			}
		}
	}
}

func (r *udpRelay) gcLoop() {
	t := time.NewTicker(2 * time.Second)
	for range t.C {
		r.mu.Lock()
		r.gcLocked()
		r.mu.Unlock()
	}
}

func (r *udpRelay) gcLocked() {
	now := time.Now()
	kept := r.socks[:0]
	for _, s := range r.socks {
		if s.conn != r.cur && now.Sub(s.created) > r.keep {
			_ = s.conn.Close()
			continue
		}
		kept = append(kept, s)
	}
	r.socks = kept
}

func (r *udpRelay) statsLoop(every time.Duration) {
	t := time.NewTicker(every)
	for range t.C {
		r.mu.Lock()
		open := len(r.socks)
		r.mu.Unlock()
		fmt.Printf("STATS up=%d down=%d n=%d o=%d\n",
			r.upBytes.Load(), r.downBytes.Load(), r.rotations.Load(), open)
	}
}

func raiseNoFile(want uint64) {
	var lim syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &lim); err != nil {
		return
	}
	target := want
	if lim.Max != ^uint64(0) && lim.Max < target {
		target = lim.Max
	}
	if lim.Cur < target {
		lim.Cur = target
		_ = syscall.Setrlimit(syscall.RLIMIT_NOFILE, &lim)
	}
}

func watchParent(pid int) {
	for {
		time.Sleep(time.Second)
		if !alive(pid) || os.Getppid() == 1 {

			os.Exit(0)
		}
	}
}

func alive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}
