---
name: Miou
version: 0.8.0
kind: library
description: A simple scheduler for OCaml 5
repo: https://github.com/robur-coop/miou
homepage: https://github.com/robur-coop/miou
tags: [scheduler, effects]
authors:
  - name: Romain Calascibetta
    email: romain.calascibetta@gmail.com
    url: https://din.osau.re/
---

Miou is what is known as a scheduler for OCaml that utilises the effects
introduced in OCaml 5 to provide a suspension and continuation mechanism that
is transparent to the user.

Miou allows you to manage so-called asynchronous tasks (i.e. tasks that run
concurrently on the same core) as well as parallel tasks (i.e. tasks that run
on a different core from the one in which they were created). Miou therefore
provides what is known as a _domain pool_ ready to manage parallel tasks.

If you're interested in the topic of schedulers and effects, [our
tutorial][miou-tutorial] on unikernels introduces you to these concepts by
helping you to implement a simple scheduler using OCaml 5.

An overview with practical examples of Miou is also available
[here][miou-overview]. These examples introduce the `Miou_unix` module, which
is **not** compatible with unikernels (and is used to create simple executables
with Miou).

## API

:::document

```ocaml
type 'a t
```

```ocaml
type 'a orphans
```

### Orphanage for tasks

In accordance with our first rule, which is to be able to wait for (or cancel)
all our tasks, there is a `orphans` value.

This value can hold _promises_ (using the `~orphans` option for the
`Miou.async` and `Miou.call` functions) and allows us to return the promise
that is in a stopped state (i.e. it has completed successfully, an exception
has been thrown from that task, or it has been cancelled). Since the tasks
returned by `orphans` are in the ‘stopped’ state, the subsequent use of
`Miou.await{,_exn}` is **non-blocking**.

Here is an example of an echo server using `orphans`. The aim is to collect
tasks that have completed during a server _tick_ (`Miou_unix.accept`) in order
to consume their results. If we did not consume the tasks, they would never be
released (and this would result in a memory leak).

'''ocaml
let rec clean_up orphans = match Miou.care orphans with
  | None -> () (* [orphans] has no task *)
  | Some None -> () (* [orphans] has no terminated task *)
  | Some (Some prm) ->
    let _ = Miou.await prm in
    clean_up orphans

let run main handler =
  let rec go orphans =
    clean_up orphans; (* clean-up *)
    let flow, _ = Miou_unix.accept main in
    (* record our new promise into [orphans] *)
    let _ = Miou.async ~orphans @@ fun () ->
      handler flow in
    go orphans in
  go (Miou.orphans ())
'''

The `orphans` can only contain tasks that are related to the **same** parent.

```ocaml
```

```ocaml
val async :
     ?give:Ownership.t list
  -> ?orphans:'a orphans
  -> (unit -> 'a)
  -> 'a t
```

`async fn` returns a _promise_ `t` representing the state of the task `fn` given as an
argument. The task will be executed **concurrently** with the other tasks in the
current domain.

It raises:
- `Invalid_argument` when we would like to attach an orphans which is **not** own by
  the parent promise. For instance, this code doesn't work because we're trying to
  attache 2 promises that don't have the same direct parent:

'''ocaml
# Miou.run @@ fun () ->
  let orphans = Miou.orphans () in
  let prm = Miou.async ~orphans @@ fun () ->
    let prm = Miou.async ~orphans (Fun.const ()) in
    Miou.await_exn prm in
  Miou.await_exn prm ;;
Exception: Invalid_argument "The given orphans is owned by another promise"
'''

```ocaml
val orphans : unit -> 'a orphans
```

:::

[miou-tutorial]: /miou-scheduler#a-hand-written-scheduler-in-ocaml
[miou-overview]: /miou-scheduler#miou-through-examples
