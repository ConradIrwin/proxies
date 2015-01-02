A collection of useful proxies that I use for debugging/testing.

## logging_proxy.rb

Written while I was at [Rapportive](https://rapportive.com), it is a transparent TCP proxy that logs any data sent and recieved. It optionally supports loading a TLS ceriticate, and it is capable of intercepting some HTTP handshakes (e.g. SMTP, HTTPS), and optionally sending the PROXY protocol upstream.

## http_proxy.rb

A simple HTTP proxy stolen from https://gist.github.com/torsten/74107#file-proxy-rb. Thanks @torsten.
