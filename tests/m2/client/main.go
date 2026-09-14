// M2 test client: connects to the supervised server, echoes a payload, closes,
// and repeats. Exercises connect / read / write / close / fd reuse and Go's
// netpoll over the broker's socketpair-backed virtual sockets.
package main

import (
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"time"
)

func one(i int) error {
	c, err := net.Dial("tcp", "10.0.0.1:179")
	if err != nil {
		return fmt.Errorf("dial: %w", err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	msg := fmt.Sprintf("hello-%04d", i)
	if _, err := c.Write([]byte(msg)); err != nil {
		return fmt.Errorf("write: %w", err)
	}
	buf := make([]byte, len(msg))
	if _, err := io.ReadFull(c, buf); err != nil {
		return fmt.Errorf("read: %w", err)
	}
	if string(buf) != msg {
		return fmt.Errorf("mismatch: got %q want %q", buf, msg)
	}
	return nil
}

func main() {
	const seq = 100
	const conc = 16

	for i := 0; i < seq; i++ {
		if err := one(i); err != nil {
			fmt.Fprintln(os.Stderr, "sequential:", err)
			os.Exit(1)
		}
	}
	fmt.Printf("sequential ok: %d connections\n", seq)

	var wg sync.WaitGroup
	errs := make(chan error, conc)
	for i := 0; i < conc; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			if err := one(seq + i); err != nil {
				errs <- err
			}
		}(i)
	}
	wg.Wait()
	close(errs)
	if err := <-errs; err != nil {
		fmt.Fprintln(os.Stderr, "concurrent:", err)
		os.Exit(1)
	}
	fmt.Printf("concurrent ok: %d connections\n", conc)
	fmt.Println("M2_CLIENT_PASS")
}
