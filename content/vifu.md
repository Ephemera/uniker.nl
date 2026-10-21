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

### Zarith

We must mention a nuance in the OCaml ecosystem: the need to use a different
version of `zarith`: specifically, `zarith` with `dune`. Therefore, to compile
the unikernels, we must `pin` our version of `zarith`.

```shell
$ opam pin add -y git+https://github.com/mirage/Zarith.git#zarith-1.14
```

## Vifu & mcrunch

So we're going to create a simple **index.html** file:

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
let index req server value =
  from_documents ~mime:"text/html" Documents.index
    req server value
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
let run _quiet stack port =
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
  $ Mnet_cli.setup "service"
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
```

In our specific case, we have to configure our cookies so that they can be
stored even though we do not use HTTPS.

```ocaml
let cookie = Vifu.Cookie.config ~secure:false ~http_only:true ()

let login req server { secret } =
  let open Vifu.Response.Syntax in
  let usernames = Vifu.Server.device usernames server in
  match Vifu.Request.of_multipart_form req with
  | Ok username when Hashtbl.mem usernames username = false ->
    let cl = Jwt.Claims.(add "username" Jsont.string username empty) in
    let token = Jwt.encode secret cl in
    let* () = Vifu.Cookie.set ~name:"jwt" server req token in
    let* () = Vifu.Response.empty in
    Hashtbl.replace usernames username ();
    Vifu.Response.redirect_to req Vifu.Uri.(rel /?? any)
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

Here, we check whether our _JWToken_ exists and display the username if it does
(which only our server can issue). Otherwise, we call our previous `index`
function, which displays the form.

```ocaml
let index req server env =
  let open Vifu.Response.Syntax in
  match Vifu.Request.get jwt req with
  | None -> index req server env
  | Some username ->
    let* () = with_textf req "Connected as %s" username in
    Vifu.Response.respond `OK
```

Vifu provides a way to describe a form using a small DSL (similar to
[`jsont`][jsont]) so that data can be easily extracted from it.

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

We're making a few changes to our `run` function.

```diff
-let run _quiet stack port =
+let run _quiet stack seed port =
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

We add a new argument to our unikernel: our seed (which is used to generate the
private key for signing our tokens).

```ocaml
let seed =
  let doc = "The seed to generate our secret (used for JWToken)." in
  let parser str = Base64.decode str in
  let pp ppf value = Fmt.string ppf (Base64.encode_string value) in
  let base64 = Arg.conv (parser, pp) in
  let open Arg in
  value & opt (some base64) None & info [ "seed" ] ~doc ~docv:"SEED"

let term =
  let open Term in
  const run
  $ Mnet_cli.setup_logs
  $ Mnet_cli.setup "service"
  $ seed $ port
```

And since we've just added a new dependency to our unikernel, we'll use `unic`
and `mfetch` again to check whether we need to download a new library. In this
case, yes - our [`jws`][jws] library. We must therefore also amend our `dune`
file accordingly to include dependencies on `jws` and `jws.jwt`.

```shell
$ unic infer -r . -x _build -x vendors --ignore Documents \
  --prefer digestif.c --prefer checkseum.c -o _mfetch
$ mfetch
# Modify your dune file!
$ dune build
```

### Test our userspace!

We can now test our little userspace!

:::annotate

Here, we're setting up our device for our unikernel.

```shell
$ sudo ip link add name service type bridge
$ sudo ip addr add 10.0.0.1/24 dev service
$ sudo ip tuntap add name tap0 mode tap
$ sudo ip link set tap0 master service
$ sudo ip link set service up
$ sudo ip link set tap0 up
$ solo5-hvt --net:service=tap0 -- _build/solo5/main.exe --ipv4=10.0.0.2/24 &
$ export PID=$!
```

We're trying to log in as "dinosaure".

```shell
$ curl -c cookie.txt -F username=dinosaure http://10.0.0.2/login
```

And we should have a cookie that proves our identity as a "dinosaure"!

```shell
$ curl -b cookie.txt http://10.0.0.2/
Connected as dinosaure
```

You can now _logout_.

```shell
$ curl -c cookie.txt -X POST http://10.0.0.2/logout
$ kill -9 $PID
```

:::

We can also use a web browser to test our unikernel. In short, we therefore
have a website with a userspace containing a _small database_ (our `Hashtbl.t`
`usernames`). We can make cookies persistent across multiple runs of our
unikernel as long as the `--seed` is set to the same value (such as `foo=`).

## Websocket

We can now take it a step further and offer a chat feature to our logged-in
users. This is where we're going to make our build pipeline a little more
complex by integrating `js_of_ocaml` and writing the necessary JavaScript
script in OCaml!

So we're going to create a page **room.html** containing a form for sending
messages and a block that receives the messages.

```html
<html>
<head>
<meta charset="utf-8">
<script type="text/javascript" defer="defer" src="script.js"></script>
<title>Chat room</title>
</head>
<body>
<form id="send">
<input type="text" name="msg" required />
<input type="submit" value="Send!" />
</form>
</body>
</html>
```

We will then create an OCaml script **script.ml** that we can compile using
`js_of_ocaml` and which uses [`brr`][brr].

:::annotate

```ocaml
let form_elem = Brr.El.find_first_by_selector (Jstr.v "#send") |> Option.get
```

This function sends a `multipart/form-data` request to `/chat` as soon as the
user clicks the `#send` button in the form.

```ocaml
let send_message ev_submit =
  let open Fut.Syntax in
  let _ = Jv.call (Brr.Ev.to_jv ev_submit) "preventDefault" [||] in
  let form_elem = Brr_io.Form.of_el form_elem in
  let form_data = Brr_io.Form.Data.of_form form_elem in
  let body = Brr_io.Fetch.Body.of_form_data form_data
  and credentials = Brr_io.Fetch.Request.Credentials.same_origin in
  let init = Brr_io.Fetch.Request.init
    ~body ~credentials ~method':(Jstr.v "POST") () in
  let req = Brr_io.Fetch.Request.v ~init (Jstr.v "/send") in
  Fut.await begin
    let* result = Brr_io.Fetch.request req in
    match result with
    | Ok resp when Brr_io.Fetch.Response.ok resp -> Fut.return ()
    | Ok _ -> print_endline "Error!"; Fut.return ()
    | Error _ -> print_endline "Error!"; Fut.return ()
  end @@ Fun.id
```

And here, as soon as a message is received from the WebSocket channel, we
create a new block containing that message.

```ocaml
let on_message ev =
  let msg = Jv.Jstr.get (Brr.Ev.to_jv ev) "data" in
  let div = Brr.El.(div [txt msg]) in
  Brr.El.append_children (Brr.Document.body Brr.G.document) [div]
```

We attach our functions correctly:
- we attach `send_message` as soon as the user `submits` a message
- we attach `on_message` as soon as a message is received from our WebSocket
  channel

```ocaml
let () =
  let socket = Brr_io.Websocket.create (Jstr.v "/chat") in
  let target = Brr_io.Websocket.as_target socket in
  let event = Brr.Ev.Type.create (Jstr.v "message") in
  ignore (Brr.Ev.listen event on_message target);
  let target = Brr.El.as_target form_elem in
  ignore (Brr.Ev.listen Brr_io.Form.Ev.submit send_message target)
```

:::

We're going to add these artefacts to our `Documents` module using `mcrunch`:

:::annotate

`dune` makes it easier to compile JavaScript scripts using `js_of_ocaml`.

```dune
(executable
 (name script)
 (modules script)
 (modes js)
 (libraries brr))

(rule
 (targets documents.ml)
 (deps index.html room.html script.bc.js)
 (action
  (with-stdout-to documents.ml
```

`dune` generates a `script.bc.js` file from the `script.ml` file using
`js_of_ocaml`. We will therefore incorporate the contents of this file into our
`Documents` module so that we can serve it via our `vifu` server.

```dune
   (run mcrunch -f script:script.bc.js 
```

And we do the same for our new document `room.html`.

```dune
                -f room:room.html
                -f index:index.html))))
```

:::

We can now implement our routes within our unikernel to handle the receipt of
new messages from users and the _broadcast_ of these messages to our WebSocket
channels.

:::annotate

We'll create our handlers, which will allow us to transfer `script.bc.js` and
`room.html` in the same way as we did with `index.html`.

```ocaml
let room req server value =
  from_documents ~mime:"text/html" Documents.room
    req server value

let script req server value =
  from_documents ~mime:"application/javascript" Documents.script
    req server value
```

Here, we're going to create a new _device_ so that we can _broadcast_ a message
globally to all clients connected to our WebSocket channel. The idea is to
create a source (see our [`flux`][flux] library on _streaming_ with Miou) that
the client can read. This source, which comes from a bounded queue, is stored
in a global `Hashtbl.t`, and as soon as a client sends a message (using
`send`), we _broadcast_ that message to all our queues so that all connected
clients can receive it via their sources.

```ocaml
type chat =
  { make : unit -> int * string Flux.source
  ; send : string -> unit
  ; shutdown : int -> unit }

let chat =
  let uid = Atomic.make 0 in
  let actives = Hashtbl.create 0x100 in
  let mutex = Miou.Mutex.create () in
  let make () =
    let n = Atomic.fetch_and_add uid 1 in
    Miou.Mutex.protect mutex @@ fun () ->
    let q = Flux.Bqueue.(create with_close) 0x7ff in
    Hashtbl.replace actives n q;
    n, Flux.Source.bqueue q in
  let shutdown uid =
    Miou.Mutex.protect mutex @@ fun () ->
    Hashtbl.remove actives uid in
  let send msg =
    Miou.Mutex.protect mutex @@ fun () ->
    let fn _ q = Flux.Bqueue.put q msg in
    Hashtbl.iter fn actives in
  let finally _ =
    Miou.Mutex.protect mutex @@ fun () ->
    let fn _ q = Flux.Bqueue.close q in
    Hashtbl.iter fn actives in
  Vifu.Device.v ~name:"chat" ~finally [] @@ fun _ ->
  { make; send; shutdown }
```

This is where our WebSocket channel is instantiated (following negotiation
between the client and the server). The aim is to connect our `oc` (for Output
Channel) to our data source. In other words, our WebSocket channel should only
send messages to clients (and, in any case, our OCaml script merely reads from
this channel; it does not send anything).

```ocaml
let websocket ic oc server _ =
  let t = Vifu.Server.device chat server in
  let uid, src = t.make () in
  let fn str = oc (`Msg (`Text, true), str) in
  let prm0 = Miou.async @@ fun () -> Flux.Source.each fn src in
  let prm1 = Miou.async @@ fun () ->
    let rec go () =
      match ic () with
      | None | Some (`Connection_close, _) ->
        oc (`Connection_close, String.empty)
      | Some _ -> go () in
    go () in
  let _ = Miou.await_first [ prm0; prm1 ] in
  t.shutdown uid
```

Meanwhile, this is where messages are sent. It's a basic HTTP POST request. We
check whether the user is online and simply use our device’s `t.send` function
to broadcast our message to all connected clients.

```ocaml
let send req server _ =
  let open Vifu.Response.Syntax in
  match Vifu.Request.of_multipart_form req, Vifu.Request.get jwt req with
  | Ok msg, Some username->
    let t = Vifu.Server.device chat server in
    let str = Fmt.str "%s: %s\n" username msg in
    t.send str;
    let* () = with_textf req "Message sent!\n" in
    Vifu.Response.respond `OK
  | Error _, _ ->
    let* () = with_textf req "Invalid multipart/form-data\n" in
    Vifu.Response.respond (`Code 422)
  | _, None ->
    let* () = with_textf req "Unauthorized!" in
    Vifu.Response.respond `Unauthorized
```

For our home page, we simply need to serve our `room.html` file from now on so
that the user has direct access to the chat.

```ocaml
let index req server env =
  match Vifu.Request.get jwt req with
  | None -> index req server env
  | Some _username -> room req server env
```

As with the `login`, we’ll describe another form - the one submitted via
JavaScript. It consists of a single `msg` field.

```ocaml
let msg =
  let open Vifu.Multipart_form in
  record Fun.id
  |+ field "msg" string
  |> sealr
```

And we can define our routes. Don't forget to define the route to our script,
and note our special route `/chat`, which initiates a negotiation between the
client and the server to instantiate a WebSocket channel.

```ocaml
let routes =
  let open Vifu.Uri in
  let open Vifu.Route in
  let open Vifu.Type in
  [ get (rel /?? nil) --> index
  ; post (m username) (rel / "login" /?? nil) --> login
  ; post any (rel / "logout" /?? nil) --> logout
  ; post (m msg) (rel / "send" /?? nil) --> send
  ; get (rel / "chat" /?? nil) --> (fun _ _ _ -> Vifu.Response.websocket)
  ; get (rel / "script.js" /?? nil) --> script ]
```

:::

All that remains is to register our new _device_ `chat` with `Vifu`, and our
unikernel is ready!

```diff
 let run _quiet stack seed port =
   Mkernel.run [ rng; stack ] @@ fun _ (_, tcp, _) () ->
   let cfg = Vifu.Config.v port in
   let secret = X509.Private_key.generate ?seed `ED25519 in
   let secret = Jws.Pk.of_private_key_exn secret in
-  let devices = Vifu.Devices.[ usernames ] in
+  let devices = Vifu.Devices.[ usernames; chat ] in
   let middlewares = Vifu.Middlewares.[ jwt ] in
   Vifu.run ~cfg ~devices ~middlewares ~websocket tcp routes { secret }
```

## Let's have a chat!

Our changes do not require us to recalculate our dependencies, as
[`flux`][flux] is already a dependency of `vifu`. However, it should be noted
that when using `unic`, we should exclude our `script.ml` file. This is because
the dependencies that can be inferred from it are not required by the
unikernel, but by `js_of_ocaml`. Furthermore, `brr` is a library that must be
installed so that `js_of_ocaml` can generate our `script.bc.js` file; however,
`brr` does not need to be _vendored_ in order to compile our unikernel.

Next, we could introduce you to a range of tools to show you how to communicate
via WebSocket and chat with others, but we'll simply advise you to connect to
your unikernel via your favourite web browser at the address
`http://10.0.0.2/`!

Finally, the aim of this chapter is to take the development of unikernels a
step further and show that it is _easy_ to integrate artefacts that are
obtained in a more complex way than simply compiling OCaml files. `js_of_ocaml`
and [`mcrunch`][mcrunch] are tools that have been a great help to us in
creating our website as a unikernel. The [`vifu`][vifu] framework has also been
quite useful. And at this stage, we’ve covered the basics of how to develop
unikernels in OCaml.

Of course, there's still plenty to discover. Our co-operative,
[robur.coop][robur.coop], has developed a whole range of [libraries][libraries]
and [unikernels][unikernels] that you can easily find on this website. We've
deliberately not covered all the protocols involved here, and we'd prefer to
let you discover them for yourselves or ask the OCaml community.

This might also be an opportunity for you to get started, create your own
unikernel and use it actively, just as we do within our co-operative.

[js_of_ocaml]: https://ocsigen.org/js_of_ocaml/latest/js_of_ocaml/index.html
[mfat]: /packages/mfat/
[vifu]: /packages/vif/
[flux]: /packages/flux/
[jws]: /packages/jws/
[jsont]: https://github.com/dbuenzli/jsont
[brr]: https://github.com/dbuenzli/brr
[mcrunch]: /packages/mcrunch
[libraries]: /packages/
[unikernels]: /unikernels/
