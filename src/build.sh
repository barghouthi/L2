#!/bin/sh

# -cflags "-w A-4-33-40-41-42-43-34-44" \
# -classic-display \

ocamlbuild \
    -use-ocamlfind \
    -syntax camlp4o \
    -pkg core \
    -pkg sexplib.syntax,comparelib.syntax,fieldslib.syntax,variantslib.syntax \
    -pkg bin_prot.syntax \
    -tag thread \
    -tag debug \
    -tag annot \
    -tag bin_annot \
    -tag short_paths \
    -cflags "-w A-4-44" \
    -cflags -strict-sequence \
    -use-menhir \
    -j 8 \
    $@
