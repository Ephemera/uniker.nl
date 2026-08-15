---
title: A unikernel with dune
description: How to build an unikernel with dune
---

This next step requires you to be familiar with `dune`, one of OCaml's build
systems. You can find out more on [its website][dune] or in [its
documentation][dune-documentation]. The official OCaml website also [documents
how to use it][ocaml-dune].

For more experienced OCaml users, `dune` isn't strictly necessary for compiling
a unikernel. As we've seen previously, `ocamlfind` may suffice, and there are
workarounds involving `ocamlbuild`. However, `dune` is currently the build
system most widely used by the OCaml community, and our unikernels are built
using it. In short, in this section we will learn how to use `dune` to build
our unikernels.

## Required files

As with any project intended to be built using `dune`, we need to create a
**dune-project** file:

```
(lang dune 3.0)
```

Next, to enable cross-compilation and compile our unikernel using our
`ocaml-solo5` toolchain, we also need to define the **dune-workspace** file:

```
(lang dune 3.0)
(context (default))
(context (default
 (name solo5)
 (host default)
 (toolchain solo5)
 (disable_dynamically_linked_foreign_archives true)))
```

In this file, we define a "context" which is added to the default context. This
means that our unikernel will be compiled **in both** the default context and
the Solo5 context. We can now define our **dune** file:

:::annotate

```
(executable
 (name main)
 (modules main)
```

Don't forget to add the flag that selects our Solo5 ABI.

```
 (link_flags :standard -cclib "-z solo5-abi=hvt")
```

```
 (libraries fmt)
 (foreign_stubs
  (language c)
```

Finally, we must always include our **manifest.o** and our **startup.o**, as
seen [earlier][manifest-and-startup].

```
  (names startup manifest)))

(rule
 (targets manifest.c)
 (enabled_if
  (= %{context_name} "default"))
 (action
  (write-file manifest.c "")))
```

We can use `dune` to generate the **manifest.c** file _on the fly_ so that we
only keep the **manifest.json** file.

```
(rule
 (targets manifest.c)
 (deps manifest.json)
 (enabled_if
  (= %{context_name} "solo5"))
 (action
  (run solo5-elftool gen-manifest manifest.json manifest.c)))
```

:::

## Our unikernel with dune

So all we need to do is write our **main.ml** file and our **manifest.json**
file (an example can be found [here][manifest]). And then build our unikernel
using `dune build`:

```ocaml
let () = Fmt.pr "Hello World!\n%!"
```

```shell
$ dune build
$ solo5-hvt _build/solo5/main.exe
            |      ___|
  __|  _ \  |  _ \ __ \
\__ \ (   | | (   |  ) |
____/\___/ _|\___/____/
Solo5: Bindings version v0.12.0
Solo5: Memory map: 512 MB addressable:
Solo5:   reserved @ (0x0 - 0xfffff)
Solo5:       text @ (0x100000 - 0x1b9fff)
Solo5:     rodata @ (0x1ba000 - 0x1e8fff)
Solo5:       data @ (0x1e9000 - 0x441fff)
Solo5:       heap >= 0x442000 < stack < 0x20000000
Hello World!
Solo5: solo5_exit(0) called
```

There you go! Your first unikernel in OCaml using `dune`. As you can see, the
artefact is located in the `_build/solo5` folder, which contains all the
targets compiled in the `ocaml-solo5` context. Later on, we'll look at how we
can both build our unikernel and build executables in the default context, and
use them in the construction of our unikernel.

[ocaml-dune]: https://ocaml.org/docs/your-first-program
[dune]: https://dune.build/
[dune-documentation]: https://dune.readthedocs.io/en/stable/
[manifest]: /hello-unikernel/#a-solo5-manifest
[manifest-and-startup]: /hello-unikernel-ocaml/
