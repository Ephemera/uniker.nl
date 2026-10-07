---
title: Your website as an unikernel
description: A step forward about developping unikernels in OCaml
---

In this final part of our tutorial, we're going to try to create a unikernel
that provides a web interface for chatting with others. I'd like to point out
that, at this stage, it can already be very interesting to build unikernels
that deal with lower-level protocols such as DNS or SSH, or simply to create
your own protocol on top of TCP/IP, and that it isn't necessarily essential to
build a _webapp_ to understand the full potential of unikernels (in fact, the
opposite is probably true).

However, this tutorial takes a brief look at how to build a unikernel by
integrating other elements, such as the output of [`js_of_ocaml`][js_of_ocaml],
or the ability to incorporate static elements into our unikernel.

## Re-introduce our workflow

Before we begin, it is important to fully understand the workflow we have
outlined here. It is important to realise that with `dune`, we build our
unikernel twice:
1) once as a simple executable capable of generating the `manifest.json` file
   required for compilation with Solo5
2) once as a unikernel using the generated `manifest.json`

In fact, `dune` has the capability to generate artefacts from software that it
has built itself. We therefore have two contexts (the default one and the Solo5
context), where the first can build **and** run software, whilst the second can
only build unikernels. `dune` then allows us to switch between these two
contexts.

For this example, we simply want to present the user with a _login_ page so
that they can log in. This page will be pure HTML, and the question is: how do
I integrate this page **statically** into my unikernel? This is where we
introduce `vifu`, our OCaml web framework, and `mcrunch`, a tool for generating
an OCaml module from files that can be statically linked.

## Vifu & mcrunch

So we’re going to create a simple **index.html** file:

```html
<html>
<head><title>uniker.nl</title></head>
<body>
<form action="/login" method="post" enctype="multipart/form-data">
  <label for="username">Enter your username: </label>
  <input type="text" name="username" required />
  <input type="submit" value="Login!" />
</form>
</body>
</html>
```

We will then build our unikernel to serve this file; in particular, we will
create a `Documents` module that exists and contains the contents of our
`index.html` file:

:::annotate

This function is a generic function that allows content to be transmitted, but
also calculates an identifier that will be set in the `ETag` field, enabling a
`Not_modified` response if the content has already been served.

In this function, we can see several aspects of `Vifu`:
1) firstly, we can see that we can inspect a received request (and look for the
   `If-None-Match` field)
2) we can also see the monad used to construct our response (adding the `ETag`
   field and responding with `Not_modified`)
3) we can also see the introduction of the `Flux` module, our stream library
   for Miou (we recommend [the documentation][flux])

We're starting to write some proper code in our unikernel.

```ocaml
let from_documents ~mime contents =
  let hash =
    let rec go ctx idx =
      if idx >= Array.length contents
      then Digestif.SHA1.(to_hex (get ctx))
      else go (Digestif.SHA1.feed_string ctx contents.(idx)) (succ idx) in
    go Digestif.SHA1.empty 0 in
  fun req _server _ ->
    let open Vifu.Response.Syntax in
    let* () = Vifu.Response.add ~field:"content-type" mime in
    let hdrs = Vifu.Request.headers req in
    let if_none_match =
      match Vifu.Headers.get hdrs "if-none-match" with
      | Some hash' -> String.equal hash hash'
      | None -> false in
    if if_none_match then
      let* () = Vifu.Response.empty in
      Vifu.Response.respond `Not_modified
    else
      let from = Flux.Source.array contents in
      let* () = Vifu.Response.add ~field:"etag" hash in
      let* () = Vifu.Response.with_source req ~compression:`DEFLATE from in
      Vifu.Response.respond `OK
```

Here, we create a specific Vifu handler for the `index` document.

```ocaml
let index = from_documents ~mime:"text/html" Documents.index
```

And we define a route to this handler. `vifu` provides a small DSL for
describing routes, ensuring that the DSL is typed. We will look at the power of
its routing system later.

```ocaml
let routes =
  let open Vifu.Uri in
  let open Vifu.Route in
  [ get (rel /?? nil) --> index ]

module RNG = Mirage_crypto_rng.Fortuna

let rng () = Mirage_crypto_rng_mkernel.initialize (module RNG)
let rng = Mkernel.map rng [] |> Mkernel.finally Mirage_crypto_rng_mkernel.kill
```

Here we have the first entry point for our unikernel, where we initialise the
HTTP server using our TCP/IP stack.

```ocaml
let run _quiet (cidr4, gateway4, ipv6, gateway6) port =
  let stack = Mnet.stack ~name:"service" ?gateway:gateway4
    ~ipv6 ?ipv6_gateway:gateway6 cidr4 in
  Mkernel.run [ rng; stack ] @@ fun _ (_, tcp, _) () ->
  let cfg = Vifu.Config.v port in
  Vifu.run ~cfg tcp routes ()
```

And finally, we set the few options needed to configure our unikernel (such as
its IP address or the port for our HTTP server). We do this using `cmdliner`.
`mnet-cli` also provides _helpers_ so that we do not have to redefine the
arguments required by our unikernel every time.

```ocaml
open Cmdliner

let port =
  let doc = "The HTTP port." in
  let open Arg in
  value & opt int 80 & info [ "p"; "port" ] ~doc ~docv:"PORT"

let term =
  let open Term in
  const run
  $ Mnet_cli.setup_logs
  $ Mnet_cli.setup
  $ port

let cmd =
  let info = Cmd.info "chat" in
  Cmd.v info term

let () = Cmd.(exit @@ eval cmd)
```

:::

Next, we're going to install a new tool: `mcrunch`. The purpose of this tool is
to generate an OCaml file that can contain the contents of one or more files.
Here's an example of how to use this tool:

```shell
$ opam install mcrunch
$ mcrunch --file index:index.html
let index =
  [| "\x3c\x68\x74\x6d\x6c\x3e\x0a\x3c\x62\x6f\x64\x79\x3e\x0a\x3c\x66"
   ; "\x6f\x72\x6d\x20\x61\x63\x74\x69\x6f\x6e\x3d\x22\x2f\x6c\x6f\x67"
   ; "\x69\x6e\x22\x20\x6d\x65\x74\x68\x6f\x64\x3d\x22\x70\x6f\x73\x74"
   ; "\x22\x20\x65\x6e\x63\x74\x79\x70\x65\x3d\x22\x6d\x75\x6c\x74\x69"
   ; "\x70\x61\x72\x74\x2f\x66\x6f\x72\x6d\x2d\x64\x61\x74\x61\x22\x3e"
   ; "\x0a\x20\x20\x3c\x6c\x61\x62\x65\x6c\x20\x66\x6f\x72\x3d\x22\x75"
   ; "\x73\x65\x72\x6e\x61\x6d\x65\x22\x3e\x45\x6e\x74\x65\x72\x20\x79"
   ; "\x6f\x75\x72\x20\x75\x73\x65\x72\x6e\x61\x6d\x65\x3a\x20\x3c\x2f"
   ; "\x6c\x61\x62\x65\x6c\x3e\x0a\x20\x20\x3c\x69\x6e\x70\x75\x74\x20"
   ; "\x74\x79\x70\x65\x3d\x22\x74\x65\x78\x74\x22\x20\x6e\x61\x6d\x65"
   ; "\x3d\x22\x75\x73\x65\x72\x6e\x61\x6d\x65\x22\x20\x72\x65\x71\x75"
   ; "\x69\x72\x65\x64\x20\x2f\x3e\x0a\x20\x20\x3c\x69\x6e\x70\x75\x74"
   ; "\x20\x74\x79\x70\x65\x3d\x22\x73\x75\x62\x6d\x69\x74\x22\x20\x76"
   ; "\x61\x6c\x75\x65\x3d\x22\x4c\x6f\x67\x69\x6e\x21\x22\x20\x2f\x3e"
   ; "\x0a\x3c\x2f\x66\x6f\x72\x6d\x3e\x0a\x3c\x2f\x62\x6f\x64\x79\x3e"
   ; "\x0a\x3c\x2f\x68\x74\x6d\x6c\x3e\x0a" |]
```

We'll use this tool to generate the `Documents` module, so we'll describe a
build pipeline that's a little more complex than the one we've used before:

:::annotate

Let's recap how to describe how to build our unikernel (don't forget the
`dune-workspace`).

```dune
(executable
 (name main)
 (modules main documents)
 (link_flags :standard -cclib "-z solo5-abi=hvt")
 (libraries mkernel mirage-crypto-rng-mkernel vifu mnet-cli)
 (foreign_stubs
  (language c)
  (names manifest)))
```

Let's use `dune` to generate the **manifest.c** file. We will then use our
executable `./main.exe` (in our `default` context) to generate our
**manifest.json** file.

```dune
(rule
 (targets manifest.c)
 (deps manifest.json)
 (enabled_if
  (= %{context_name} "solo5"))
 (action
  (run solo5-elftool gen-manifest manifest.json manifest.c)))

(rule
 (targets manifest.c)
 (enabled_if
  (= %{context_name} "default"))
 (action
  (write-file manifest.c "")))
```

And that's how you can describe how to build the `Documents` module using
`dune` and `mcrunch`.

```dune
(rule
 (targets documents.ml)
 (deps index.html)
 (action
  (with-stdout-to documents.ml (run mcrunch -f index:index.html))))
```

:::

With all this, we'll be able to:
1) work out the dependencies using `unic`
2) download the necessary source code using `mfetch`
3) generate our **manifest.json** using `dune`
4) and finally build our unikernel!

```shell
$ unic infer -r . -x _build -x vendors --ignore Documents \
  --prefer digestif.c --prefer checkseum.c -o _mfetch
$ mfetch --with-dune-file
$ dune exec ./main.exe -- --ipv4=0.0.0.0/0 > manifest.json
$ dune build
```

You can try out our unikernel right now:

```shell
$ sudo ip tuntap add name tap0 mode tap
$ sudo ip link set tap0 up
$ sudo ip link add name service type bridge
$ sudo ip link set service up
$ sudo ip link set tap0 master service
$ sudo ip addr add 10.0.0.1/24 dev service
$ solo5-hvt --net:service=tap0 -- _build/solo5/main.exe --ipv4=10.0.0.2/24 &
$ PID=$!
$ curl http://10.0.0.2/
<html>
<head><title>uniker.nl</title></head>
<body>
<form action="/login" method="post" enctype="multipart/form-data">
  <label for="username">Enter your username: </label>
  <input type="text" name="username" required />
  <input type="submit" value="Login!" />
</form>
</body>
</html>
$ kill -9 $PID
```

We've built our first website using a unikernel! As you can see, it's not that
difficult, as [`vifu`][vifu] provides everything we need to map HTTP routes to
OCaml functions. With that in mind, we recommend you find out more about this
web framework.

We've also seen how to statically embed content into our unikernel from an
external file using `mcrunch`. This is very handy, but it's important to bear
in mind that it isn't the only way to embed files into our unikernel, as it has
a direct impact on your unikernel's memory usage. In this context, we mentioned
[`mfat`][mfat], which uses a block device that is more memory-efficient. It all
depends on what you want to achieve. `mcrunch` has the advantage of being very
simple and requiring no dependencies.

This has enabled us to make our build pipeline a little more complex and to
understand that we can generate artefacts that will be necessary for building
our unikernel.

## A simple login

Let's take our unikernel a step further. We're going to create a mini database
system where users can assign themselves a unique username and the server
returns a _JWToken_ representing that username. We'll therefore be making more
extensive use of `vifu` and also using our [`jws`][jws] library, which
implements JWTokens in OCaml:

:::annotate

```ocaml
let with_textf req fmt = Fmt.kstr (Vifu.Response.with_text req) fmt
```

In a web application, we often refer to the `.env` file, which contains
information relating to the web server, such as the database password. We're
applying a similar principle here with this type, the value of which will be
available across all our handlers.

```ocaml
type env = { secret : Jws.Pk.t }
```

`vifu` provides an object called `device`, which is global and can be accessed
from all handlers using the `server` value. This will allow us to have a small
global database (a simple `Hashtbl`) that we can access from all our handlers.

```ocaml
let usernames =
  let finally = Fun.const () in
  Vifu.Device.v ~name:"usernames" ~finally [] @@ fun _ ->
  Hashtbl.create 0x7ff
```

Like any web framework, `vifu` also provides middleware. The aim here is to
retrieve any cookies and extract the `username` from the JWToken that can be
extracted. Any errors return `None`.

```ocaml
let jwt =
  Vifu.Middlewares.v ~name:"jwt" @@ fun req _target server { secret } ->
  match Vifu.Cookie.get server req ~name:"jwt" with
  | Error _err -> None
  | Ok token ->
    let ( let* ) = Option.bind in
    let public = Jws.Pk.public secret in
    let token = Jwt.decode ~public token in
    let* token = Result.to_option token in
    Jwt.value token ~key:"username" Jsont.string

let login req server { secret } =
  let open Vifu.Response.Syntax in
  let usernames = Vifu.Server.device usernames server in
  match Vifu.Request.of_multipart_form req with
  | Ok username when Hashtbl.mem usernames username = false ->
    let cl = Jwt.Claims.(add "username" Jsont.string username empty) in
    let token = Jwt.encode secret cl in
    let* () = Vifu.Cookie.set ~name:"jwt" server req token in
    let* () = Vifu.Response.empty in
    Vifu.Response.redirect_to req Vifu.Uri.(rel / "chat" /?? any)
  | Ok username ->
    let* () = with_textf req "%s is already taken!\n" username in
    Vifu.Response.respond `Conflict
  | Error _ ->
    let* () = with_textf req "Invalid multipart/form-data\n" in
    Vifu.Response.respond (`Code 422)

let logout req server _ =
  let open Vifu.Response.Syntax in
  let usernames = Vifu.Server.device usernames server in
  let fn = Hashtbl.remove usernames in
  Option.iter fn (Vifu.Request.get jwt req);
  let* () = Vifu.Cookie.set ~name:"jwt" server req String.empty in
  let* () = Vifu.Response.empty in
  Vifu.Response.redirect_to req Vifu.Uri.(rel /?? any)
```

:::

:::annotate

```ocaml
let username =
  let open Vifu.Multipart_form in
  record Fun.id
  |+ field "username" string
  |> sealr

let routes =
  let open Vifu.Uri in
  let open Vifu.Route in
  let open Vifu.Type in
  [ get (rel /?? nil) --> index
  ; post (m username) (rel / "login" /?? nil) --> login
  ; post any (rel / "logout" /?? nil) --> logout ]
```

:::

```diff
-let run _quiet (cidr4, gateway4, ipv6, gateway6) port =
+let run _quiet (cidr4, gateway4, ipv6, gateway6) seed port =
   let stack = Mnet.stack ~name:"service" ?gateway:gateway4
     ~ipv6 ?ipv6_gateway:gateway6 cidr4 in
   Mkernel.run [ rng; stack ] @@ fun _ (_, tcp, _) () ->
   let cfg = Vifu.Config.v port in
+  let secret = X509.Private_key.generate ?seed `ED25519 in
+  let secret = Jws.Pk.of_private_key_exn secret in
+  let devices = Vifu.Devices.[ usernames ] in
+  let middlewares = Vifu.Middlewares.[ jwt ] in
-  Vifu.run ~cfg tcp routes ()
+  Vifu.run ~cfg ~devices ~middlewares tcp routes { secret }
```

```shell
$ unic infer -r . -x _build -x vendors --ignore Documents \
  --prefer digestif.c --prefer checkseum.c -o _mfetch
$ mfetch
$ dune build
```

[js_of_ocaml]: https://ocsigen.org/js_of_ocaml/latest/js_of_ocaml/index.html
[mfat]: /packages/mfat/
[vifu]: /packages/vif/
[flux]: /packages/flux/
[jws]: /packages/jws/
