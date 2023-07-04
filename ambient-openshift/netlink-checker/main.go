package main

import (
	"os"
	"fmt"
	"net"
	"strconv"
	"time"

	"github.com/vishvananda/netlink"
)

func main() {
	for {
		time.Sleep(2 * time.Second)

		ip := os.Getenv("IP")
		if ip == "" {
			ip = "127.0.0.1"
		}
		mask := os.Getenv("MASK")
		if mask == "" {
			mask = "32"
		}
		fmt.Printf("Checking routes for %s/%s\n", ip, mask)
		ones, err := strconv.Atoi(mask)
		if err != nil {
			fmt.Printf("failed to cast mask %s: %s\n", mask, err)
			continue
		}

		routes, err := netlink.RouteListFiltered(
			netlink.FAMILY_V4,
			&netlink.Route{Dst: &net.IPNet{IP: net.ParseIP(ip), Mask: net.CIDRMask(ones, 32)}},
			netlink.RT_FILTER_DST,
		)

		if err != nil {
			fmt.Printf("failed to get routes: %s\n", err)
			continue
		}

		if len(routes) == 0 {
			fmt.Printf("did not find any route\n")
			continue
		}

		for i, r := range routes {
			fmt.Printf("%d. Route: %s\n", i, r.String())
		}
		fmt.Println("Done")
	}
}
