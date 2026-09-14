// M2 test server: an ordinary Go TCP server. It is launched under AnyREAL
// supervision; the broker virtualizes its AF_INET TCP socket.
package main

import (
	"fmt"
	"io"
	"net"
	"os"
)

func main() {
	ln, err := net.Listen("tcp", "0.0.0.0:179")
	if err != nil {
		fmt.Fprintln(os.Stderr, "listen:", err)
		os.Exit(1)
	}
	fmt.Println("SERVER_READY")
	for {
		c, err := ln.Accept()
		if err != nil {
			fmt.Fprintln(os.Stderr, "accept:", err)
			continue
		}
		go func(c net.Conn) {
			defer c.Close()
			io.Copy(c, c) // echo
		}(c)
	}
}
