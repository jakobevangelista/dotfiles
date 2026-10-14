// h2c-proxy bridges the node's development h2c enrollment client to the HTTP/1 API.
package main

import (
	"flag"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:28091", "proxy listen address")
	upstream := flag.String("upstream", "http://127.0.0.1:28090", "API URL")
	flag.Parse()
	u, err := url.Parse(*upstream)
	if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") {
		log.Fatal("upstream must be an http or https URL with a host")
	}
	p := new(http.Protocols)
	p.SetHTTP1(true)
	p.SetUnencryptedHTTP2(true)
	s := &http.Server{Addr: *listen, Handler: httputil.NewSingleHostReverseProxy(u), Protocols: p}
	log.Fatal(s.ListenAndServe())
}
