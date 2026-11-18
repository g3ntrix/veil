package main

import (
	"fmt"
	"os"
)

const version = "1.0.0"

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	var err error
	switch os.Args[1] {
	case "run":
		err = runRelay(os.Args[2:])
	case "probe":
		err = runProbe(os.Args[2:])
	case "guard":
		err = runGuard(os.Args[2:])
	case "version", "--version", "-v":
		fmt.Println(version)
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "relayd:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage error")
	os.Exit(2)
}
