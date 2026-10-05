#+test
package headless

import "core:testing"
import "core:time"

@(test)
a_datagram_crosses_the_loopback_interface_and_close_stops_the_thread :: proc(t: ^testing.T) {
	a, a_err := open(0)
	testing.expect_value(t, a_err, nil)
	defer close(a)
	b, b_err := open(0)
	testing.expect_value(t, b_err, nil)
	defer close(b)

	hello := "hello"
	send(b, loopback(a.port), transmute([]byte)hello)
	for _ in 0 ..< 2000 {
		if datagram, ok := receive(a); ok {
			testing.expect_value(t, string(datagram_bytes(&datagram)), "hello")
			testing.expect_value(t, datagram.from.port, b.port)
			return
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, false, "no datagram arrived")
}
