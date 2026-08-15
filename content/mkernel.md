---
title: Mkernel, our scheduler for our unikernels
description: A derivation of Miou for unikernels
---

Following this brief digression on the scheduler, it may be worth using Miou
and `mkernel` to develop our unikernels. In this case, `mkernel` extends Miou
to handle all I/O-related tasks with Solo5.

As mentioned, Solo5 is very minimal and offers only two devices: what is known
as a network interface (which can easily be thought of as an Ethernet socket)
and what is known as a block device (which can easily be thought of as a hard
drive).

It is through these two types of devices that we obtain four _hypercalls_: that
is to say, functions that interact with these devices:
1) read an Ethernet frame
2) write an Ethernet frame
3) read a page from a block device
4) write a page to a block device

This is how `mkernel` essentially offers two things:
1) integration of these hypercalls with the Miou scheduler
2) the ability to specify the devices required for your unikernel

## Your first unikernel with `mkernel`

If we go back to our example with `dune`, we simply need to add `mkernel` as a
dependency for our unikernel. This library, just as we explained with regard to
`digestif`, contains C stubs, so it must be marked as a vendor library:

```ocaml
let () = Mkernel.(run []) @@ fun () ->
  print_endline "Hello World!"
```

```shell
$ unic infer -r . -x _build -x vendors > _mfetch
$ mfetch --with-dune-file
mkernel                          ok
$ dune build
$ solo5-hvt -- _build/solo5/main.exe --solo5:quiet
Hello World!
```

It is worth noting that the [**startup.c**][startup] file we used to have to
write is no longer needed. This is because `mkernel` implements it for us.

Next, unlike `Miou{,_unix}.run`, our `Mkernel.run` function takes a rather
special list: the one that specifies our devices. Let’s give it a go with a
_block device_:

```ocaml
let () = Mkernel.(run [ block "disk" ]) @@ fun blk () ->
  let bstr = Bstr.create (Mkernel.Block.pagesize blk) in
  Mkernel.Block.atomic_read blk ~src_off:0 bstr;
  Fmt.pr "@[<hov>%a@]" (Hxd_string.pp Hxd.default) (Bstr.to_string bstr)
```

When extending our code, there are several things to do:
1) We need to modify the `dune` file to include the new libraries `bstr`,
   `hxd.core` and `hxd.string` (for HexDump)
2) we must double-check whether adding these libraries means (or not) that some
   of them need to be marked as vendor libraries (we must therefore run `unic
   infer` again)
3) if we need to mark some of them as vendor libraries, we can re-run `mfetch`
4) Adding a device to our unikernel also requires a change to our
   **manifest.json**. There's a handy trick for this last task!

:::annotate

```shell
$ unic infer -r . -x _build -x vendors > _mfetch
```

Here, we can see that we need to use `bstr`; it’s a small library for
manipulating bigarrays.

```shell
$ mfetch
bstr                             ok
mkernel                          skipped (already vendored)
```

Here's a tip for generating the **manifest.json**. When we compile our
unikernel, we compile it twice: once for Solo5 and once using the default
context. As for the default context, it's a simple executable produced from the
same code (i.e. the same `main.ml`).

From this code, we can infer which devices have been added to `Mkernel.run` and
generate our **manifest.json** accordingly. We could even turn this into a
`dune` rule!

```shell
$ dune exec ./main.exe > manifest.json
$ dune build
```

Let's create a block device `file.txt`. It must be aligned to our default page
(512 bytes).

```shell
$ echo "Hello World!" > file.txt
$ truncate -s 512 file.txt
$ solo5-hvt --block:disk=file.txt -- _build/solo5/main.exe --solo5:quiet
00000000: 4865 6c6c 6f20 576f 726c 6421 0a00 0000  Hello World!....
...
```

:::

We've manipulated our first block device in our unikernel! As we can see, we
assign a name to a device. This is the name that will be used when we want to
run our unikernel (in this case, "disk").

Next, we associate a file called `file.txt` with it, which contains our "Hello
World", and we display it using `fmt` and `hxd`. We’ve made a _hypercall_:
specifically, reading a page (512 bytes) from the given block device.

We also have the complete workflow for developing a unikernel, specifically
this loop involving adding dependencies, determining what needs to be
vendorised using `unic`, and downloading the source code.

## Our bootagotchi

At this stage, we're going to implement a proper unikernel using a block
device. The aim is to create our own little [Tamagotchi][tamagotchi], but in
the form of a unikernel: this draws a parallel with real life, as we try, at
[robur][robur] to look after our deployed unikernels on a daily basis. The
principle is simple: to be able to _save_ the state of our Tamagotchi to a
block device.

:::annotate

```ocaml
type state =
  { boots : int32
  ; health : int32 }
```

`Bin` is a module that allows you to define a binary format which can then be
encoded and decoded.

```ocaml
let state =
  let open Bin in
  record (fun boots health -> { boots; health })
  |+ field beint32 (fun t -> t.boots)
  |+ field beint32 (fun t -> t.health)
  |> sealr

let encode blk value =
  let bstr = Bstr.create (Mkernel.Block.pagesize blk) in
```

One of the advantages of `Bin` is that it may be able to infer the size of a
value as it serialises it. Here, we check that what we want to encode is
smaller than a page.

```ocaml
  let size = Bin.size_of_value state value in
  let fn size =
    if size > Mkernel.Block.pagesize blk
    then Fmt.failwith "Impossible to encode our state into the given block \
                       device (its page is too small)" in
  Option.iter fn size;
  Mkernel.Block.atomic_read blk ~src_off:0 bstr;
  Bin.encode_bstr state value bstr (ref 0);
  Mkernel.Block.atomic_write blk ~dst_off:0 bstr

let decode blk =
  let bstr = Bstr.create (Mkernel.Block.pagesize blk) in
  Mkernel.Block.atomic_read blk ~src_off:0 bstr;
  match Bin.decode_bstr state bstr (ref 0) with
  | value -> value
  | exception _ -> Fmt.failwith "Invalid block device"
```

:::

We can therefore create the core of our unikernel, which involves retrieving
the state of our _bootagotchi_ and displaying it:

```ocaml
let show state = match state.health with
  | n when n <= 0l ->
    Fmt.pr
{text|
  /\_/\
 ( x.x ) [Boot #%ld]
  > ^ <
|text} state.boots
  | n ->
    Fmt.pr
{text| 
  /\_/\
 ( o.o ) [Boot #%ld]
  > ^ <  [Health: %ld/100]
|text} state.boots (Int32.min state.health 100l)

let run feed = Mkernel.(run [ block "bootagotchi" ] @@ fun blk () ->
  let state = decode blk in
  let state = { state with health= Int32.add state.health feed } in
  show state;
  let next = { boots= Int32.succ state.boots
             ; health= Int32.pred state.health } in
  encode blk next

open Cmdliner

let feed =
  let doc = "Give some food to your bootagotchi." in
  Arg.(value & opt int32 0l & info [ "feed" ] ~doc)

let term =
  let open Term in
  const run $ feed

let cmd = Cmd.v (Cmd.info "bootagotchi") term

let () = Cmd.(exit @@ eval' cmd)
```

We're going to add our `dune` file to our project. This will use a trick to
generate the **manifest.json** on the fly.

:::annotate

```lisp
(executable
 (name main)
 (modules main)
 (link_flags :standard -cclib "-z solo5-abi=hvt")
 (libraries cmdliner mkernel fmt bin bstr)
 (foreign_stubs
  (language c)
  (names manifest)))

(rule
 (targets manifest.c)
 (deps manifest.json)
 (enabled_if
  (= %{context_name} "solo5"))
 (action
  (run solo5-elftool gen-manifest manifest.json manifest.c)))
```

If we want to compile our unikernel in the default context (as a simple
executable), the **manifest.c** file can be left blank.

```lisp
(rule
 (targets manifest.c)
 (enabled_if
  (= %{context_name} "default"))
 (action (write-file manifest.c "")))
```

However (and this is the trick), as soon as we compile our unikernel within the
Solo5 environment, we’ll run that same unikernel as a simple executable in
order to generate our **manifest.json** based on the arguments we pass to
`Mkernel.run`.

```lisp
(rule
 (target manifest.json)
 (enabled_if
  (= %{context_name} "solo5"))
 (action
  (with-stdout-to manifest.json (run ./main.exe))))
```

:::

So we can now follow our workflow and run our unikernel!

```shell
$ unic -r . -x _build -x vendors > _mfetch
$ mfetch
bin                              ok (bin, bstr)
mkernel                          ok
$ dune build
$ touch state.img
$ truncate -s 512 state.img
$ solo5-hvt --block:bootagotchi=state.img -- \
  _build/solo5/main.exe --solo5:quiet --feed 3
 
  /\_/\
 ( o.o ) [Boot #0]
  > ^ <  [Health: 3/100]
$ solo5-hvt --block:bootagotchi=state.img -- \
  _build/solo5/main.exe --solo5:quiet
 
  /\_/\
 ( o.o ) [Boot #1]
  > ^ <  [Health: 2/100]
$ solo5-hvt --block:bootagotchi=state.img -- \
  _build/solo5/main.exe --solo5:quiet
 
  /\_/\
 ( o.o ) [Boot #2]
  > ^ <  [Health: 1/100]
$ solo5-hvt --block:bootagotchi=state.img -- \
  _build/solo5/main.exe --solo5:quiet

  /\_/\
 ( x.x ) [Boot #3]
  > ^ <
```

And here's our first _bootagotchi_! `Mkernel` provides the most basic
_hypercalls_ for interacting with block devices. As such, we've also been able
to develop a library such as [`cachet`][cachet] that allows us to cache page
reads (as the hypercall can be quite costly) whilst also enabling us to write
values of arbitrary size without being constrained by page boundaries.

### A filesystem for our unikernel

Finally, a block device can be extended to support more complex operations,
such as treating it as a FAT32 file system. That is why we have developed
[`mfat`][mfat], an OCaml implementation of FAT32, and here is how we could use
it with `mkernel`:

```ocaml
module Blk = struct
  type t = Mkernel.Block.t

  let pagesize = Mkernel.Block.pagesize
  let read = Mkernel.Block.atomic_read
  let write = Mkernel.Block.atomic_write
end

module FAT32 = Mfat_bos.Make (Blk)

let fat32 name =
  let fn blk () =
    let v = FAT32.create blk in
    let v = Result.map_error (fun (`Msg msg) -> msg) v in
    Result.error_to_failure v in
  Mkernel.map fn [ Mkernel.block name ]

let run _ =
  Mkernel.(run [ fat32 "disk" ]) @@ fun fs () ->
  ...
```

## Time to stop!

We're going to look at one final aspect of `mkernel` that comes directly from
Miou: tasks. Thanks to Miou, it's possible to launch tasks and let the
scheduler run them. So here we're going to have a bit of fun with time and
tasks to make the unikernel a little more _dynamic_.

:::annotate

```ocaml
let or_raise = function Ok v -> v | Error exn -> raise exn

let rec loop time str =
  Mkernel.sleep time;
  Fmt.pr "%s%!" str;
  loop time str

let _500ms = 500_000_000
let _1s = 1_000_000_000
let _5s = 5_000_000_000

let () = Mkernel.(run []) @@ fun () ->
```

The aim here is to have two tasks that will run **simultaneously** and will be
cancelled after 5 seconds.

```ocaml
  let prm0 = Miou.async @@ fun () -> loop _500ms "." in
  let prm1 = Miou.async @@ fun () -> loop _1s "o" in
  let prm3 = Miou.asycn @@ fun () ->
    Mkernel.sleep _5s;
    print_endline "Bing!" in
  Miou.await_first [ prm0; prm1; prm3 ] |> or_raise
```

:::

You can compile it and get a little animation!

![foo](/static/bing.gif)

## Conclusion

We're already starting to have a bit of fun with `mkernel`. We now have a
scheduler that can, amongst other things, handle block devices and run
asynchronous tasks simultaneously. With that in mind, our brief introduction to
[Miou][miou-tutorial] might help you take things further. The documentation for
[`mkernel`][mkernel] is also worth a look.

However, handling block devices is certainly not enough, which is why, in the next section, we’ll introduce you to using `mnet` and networking!

[robur]: https://robur.coop/
[tamagotchi]: https://en.wikipedia.org/wiki/Tamagotchi
[startup]: /hello-unikernel-ocaml/
[cachet]: /packages/cachet
[mfat]: /packages/mfat
[miou-tutorial]: /miou-scheduler
[mkernel]: /packages/mkernel
