---
title: Unikernels and libraries
description: How to use libraries in my unikernel?
---

One limitation specific to compiling unikernels is the use of OCaml libraries
containing what are known as "C stubs". As shown in the previous example, using
a pure OCaml library for our unikernel (like `fmt`) involves no additional
difficulty other than specifying that library in the `(libraries ...)` section
of `dune`. This is mainly because `ocaml-solo5` compiles OCaml files in the
same way as your host compiler. However, this is not the case for C files.

Let's take the `digestif` library as an example. It is used to calculate hashes
and, naturally, is implemented in C. If we were to use it in our unikernel, we
would encounter a surprising and difficult-to-reproduce runtime error.

### Vendoring

For this type of dependency, to ensure that the C files are compiled
consistently and linked to the unikernel, we need to 'vendor' them: that is,
download the source code and let `dune` orchestrate the compilation of these
sources within the context of `ocaml-solo5`. This means that the dependency
**must** also use `dune`.

In the case of `digestif`, we must therefore not only add a new `dune`
directive: `(vendored_dirs vendors)`, but also obtain the source code for
`digestif`:

```ocaml
let () =
  let open Digestif in
  let ctx = SHA256.empty in
  let ctx = SHA256.feed_string ctx "Hello World!" in
  let hash = SHA256.get ctx in
  Fmt.pr "%a\n%!" SHA256.pp hash
```

```shell
$ mkdir vendors
$ opam source digestif --dir vendors/digestif
$ dune build
$ solo5-hvt _build/solo5/main.exe --solo5:quiet
7f83b1657ff1fc53b92dc18148a1d65dfc2d4b1fa3d677284addd200126d9069
```

### Tools

This requirement to 'vendor' may seem straightforward and can be described as
follows: all dependencies containing C stubs must use `dune` and be
_vendorised_.  However, a library written entirely in OCaml that uses, either
directly or indirectly, a library containing C stubs **must also** be
vendorised. It is for this reason that we have developed the `unic` tool, which
allows us to infer what needs to be vendorised:

```shell
$ opam install unic
$ unic infer -r -x _build -x vendors .
Module Digestif is provided by several ocamlfind packages:
  [0] digestif.c
  [1] digestif.ocaml
Pick one [0-1]: 0
digestif
```

In this example, the tool offers two implementations of `digestif` (one in C
and one in OCaml), and we select the C one. The result is then displayed,
and we can see that `fmt` is not one of the libraries that need to be bundled
(even though we are using it).

We now know what is required for the build, and all we need to do is save this
list to a **\_mfetch** file, after which a new tool called `mfetch` will
download the dependencies.

```shell
$ rm -rf vendors
$ unic infer -r -x _build -x vendors . --prefer digestif.c > _mfetch
$ mfetch
digestif                         ok
$ dune build
```

## Workflow

Using these two tools, the workflow for developing unikernels becomes seamless:
1) You develop your project as a simple `dune` executable, but with
   cross-compilation using `ocaml-solo5` enabled
2) when adding dependencies, you need to check whether they need to be vendored
   (as they directly or indirectly use libraries containing C files). This is
   where the `unic` tool comes in.
3) we then simply download the necessary dependencies using `mfetch`

## Conclusion

At this stage, we have practically everything we need to develop unikernels in
OCaml. The question now is: what, and how? In the following chapters, we will
explore the use of certain libraries that will help you create your own
unikernels.
