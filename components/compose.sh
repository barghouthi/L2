echo "" > all.ml
cat ints.ml >> all.ml
cat ints-ext.ml >> all.ml
cat lists.ml >> all.ml
cat pairs.ml >> all.ml

echo ""  > ints-ext-pairs.ml
cat ints.ml >> ints-ext-pairs.ml
cat ints-ext.ml >> ints-ext-pairs.ml
cat pairs.ml >> ints-ext-pairs.ml


echo ""  > ints-pairs.ml
cat ints.ml >> ints-pairs.ml
cat pairs.ml >> ints-pairs.ml

echo "" > ints-lists.ml
cat ints.ml >> ints-lists.ml
cat lists.ml >> ints-lists.ml
