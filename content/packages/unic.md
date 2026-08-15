---
name: unic
version: 0.1.0
kind: tool
description: A tool to infer dependencies which must be vendored for unikernels
repo: https://git.robur.coop/robur/unic
homepage: https://git.robur.coop/robur/unic
tags: [workflow, dependencies]
authors:
  - name: Romain Calascibetta
    email: romain.calascibetta@gmail.com
    url: https://din.osau.re/
---

`unic` is a tool that analyses an OCaml project in order to infer the
dependencies required by that project, which must be _vendored_ to enable the
static linking of an executable/unikernel and the compilation of C source files
using the correct OCaml toolchain. Its aims is to resolve the issue of how to
produce a statically linked executable whose artefacts are compiled
consistently. This is a particular challenge when it comes to unikernels, as
the C source files must be compiled using our Solo5 toolchain (which, amongst
other things, excludes the host system's standard C library).

It is a tool that **does not depend** on a build system (such as
[`dune`][dune]) and uses [`codept`][codept] to infer dependencies. Let’s take
this simple example:

:::annotate

```shell
$ cat >main.ml<<EOF
let () =
  Mirage_crypto_rng_unix.use_default ();
  let buf = Bytes.create 0x7ff in
  Mirage_crypto_rng.generate_into buf (Bytes.length buf);
  Fmt.pr "@[<hov>%a@]\n%!" (Hxd_string.pp Hxd.default)
    (Bytes.unsafe_to_string buf)
EOF
$ unic infer .
```

Here, `unic` asks you which implementation of `digestif` you would like. We
choose `digestif.c`.

```shell
Module Digestif is provided by several ocamlfind packages:
  [0] digestif.c
  [1] digestif.ocaml
Pick one [0-1]: 0
```

It should be noted that `fmt` and `hxd` are not included amongst the
dependencies to be bundled. This is simply because these libraries are
implemented in pure OCaml and do not transitively depend on libraries
containing C files.

```shell
digestif
mirage-crypto
mirage-crypto-rng
```

:::

Next, you can save the result to a `_mfetch` file and use the
[`mfetch`][mfetch] tool to download the source code for these projects.

There are also several options available to fine-tune the resolution produced
by `unic`:
- `-r` / `--recursive` allows you to include all the files in the current folder
  and its subfolders.
- `-x` / `--exclude` allows you to exclude folders or files from the resolution
  (for example, it may be useful to exclude the folder where we have packaged
  our dependencies, as well as the `_build` folder)www
- `--forbid` allows you to exclude a specific module from the dependency graph.
  This is particularly useful for unikernels, for example, to exclude the `Unix`
  module.
- `-p` / `--prefer` allows you to specify a ‘preferred’ library if there are
  several options available. For example, you could specify `--prefer
  digestif.c` in our example so that the resolver selects this dependency rather
  than asking you to choose.

  It is also possible to specify which module's library you wish to prioritise
  using `--prefer Digestif:digestif.c`
- `-i` / `--ignore` allows a required module to be ignored during resolution.
  There may be modules that are generated _on the fly_ and are therefore not
  present at the time of resolution.

[codept]: https://github.com/Octachron/codept
[dune]: https://dune.build/
[mfetch]: /packages/mfetch/
