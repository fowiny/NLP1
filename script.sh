# Initialise the names of the methods in an array 
METHOD[1]="witten_bell"
METHOD[2]="absolute"
METHOD[3]="katz"
METHOD[4]="kneser_ney"
METHOD[5]="presmoothed"
METHOD[6]="unsmoothed"

#The number of occurrences of each POS tag in the training data
echo "Counting POS..."
cat NLSPARQL.train.data | cut -f 2 | sed '/^\s*$/d' | sort | uniq -c | sed 's/^ *//g' |awk '{OFS="\t"; print $2,$1}' > POS.counts

#A transducer is built by adding 0 to the result(TOK_POS.probs) in positions from_state and to_state
echo "Calculating Probability of word given tag..."
cat NLSPARQL.train.data | sed '/^ *$/d' | sort | uniq -c | sed 's/^ *//g' |awk '{OFS="\t"; print $2,$3,$1}' > TOK_POS.counts

#The probability that a token takes a particular tag is calculated based on the counts obtained previously
echo "Calculating the Probability that a word occurs given a tag..."
while read token pos count;  do poscount=$(grep "$pos" POS.counts | cut -f 2 | head -n1);  prob=$(echo "-l($count / $poscount)" | bc -l);  echo -e "$token\t$pos\t$prob"; done < TOK_POS.counts > TOK_POS.probs

#The test data contains tokens not found in train data; so a separate transducer is built for tagging unknown texts
echo "Building transducer..."
while read token pos prob; do echo -en "0\t0\t"; echo -e "$token\t$pos\t$prob"; done < TOK_POS.probs >TOK1_POS.probs
echo "0">>TOK1_POS.probs

#The testing data may contain tokens not found in training data. So a separate transducer is build for tagging unknown texts
echo "Building Transducer for unknown_text..."
while read token count; do prob=$(echo "-l(1/41)" | bc -l); echo -e "0\t0\t<unk>\t$token\t$prob"; done < POS.counts >unknown.txt
echo "0">>unknown.txt

#The input lexicon is built from train data
echo "Building input lexicon..."
cat TOK_POS.counts | sed '/^ *$/d' | sort | uniq -c |awk '{OFS="\t"; print $2}' >tokens.txt
cat tokens.txt | sed '/^ *$/d' | sort | uniq -c |awk '{OFS="\t"; print $2}' >tokens1.txt
VAR=0
echo -e "<eps>\t0" > input.lex
while read token; do let "VAR++"; echo -e "$token\t$VAR"; done < tokens1.txt >> input.lex
let "VAR++"
#The <unk> is also added to input lexicon as the test data may contain different tokens from training data.
echo -e "<unk>\t$VAR" >> input.lex

# the same is repeated for the output lexicon
echo "Building output lexicon..."
VAR=0
echo -e "<eps>\t0" > output.lex
while read token count; do let "VAR++"; echo -e "$token\t$VAR"; done < POS.counts >> output.lex
let "VAR++"
echo -e "<unk>\t$VAR" >> output.lex

#The transducer built on the training data is compiles 
echo "Compiling the built transducer..."
fstcompile --isymbols=input.lex --osymbols=output.lex TOK1_POS.probs > A.fst

#The transducer built for the unknown text is compiles
echo "Compiling transducer for unknown_text..."
fstcompile --isymbols=input.lex --osymbols=output.lex unknown.txt > U.fst

#The compiles transducers for training data and unknown token are combined using fst_union
echo "fst_union between built tranducer..."
fstunion A.fst U.fst | fstclosure > train.fst

#The POS tags are retrieved from the training data and output as they appear in train data for each sentence
cat NLSPARQL.train.data | cut -f 2 | sed 's/^ *$/#/g' | tr '\n' ' ' | tr '#' '\n' | sed 's/^ *//g;s/ *$//g' > POS_tag_train.txt

#POS_tags are compiled and output in train.far
farcompilestrings --symbols=output.lex --keep_symbols=1 --unknown_symbol='<unk>' POS_tag_train.txt > train.far

#The test data is retrieved from the file and output in sentence format
echo "Converting token-per-line format to POs_tag sentence-per-line format..."
cat NLSPARQL.test.data | cut -f 1 | sed 's/^ *$/#/g' | tr '\n' ' ' | tr '#' '\n' | sed 's/^ *//g;s/ *$//g' > POS_tag_test.txt

#The output sentences are compiled together and output to test.far
farcompilestrings --symbols=input.lex --unknown_symbol='<unk>' POS_tag_test.txt > test.far

#The compiled strings are extracted and output to separate files using farextract
farextract test.far

#A loop is performed to automate and obtain results for each method 
for i in $(seq 1 6)
do
	#A text file accuracy.data is created to accumulate the results of every method
	echo -e "Method : ${METHOD[$i]}" >> accuracy.data
	#Ngram_order looped over 1 to 5 for each method
	for ORDER in 1 2 3 4 5 6 7 8 9
	do 
		echo -e "\tNgram_Order : $ORDER\t\c" >>accuracy.data
		echo "Training model with Method :${METHOD[$i]} with ngram_order :$ORDER ..."
		#Creating ngrammodel using the training data which was compiled earlier as train.far
		ngramcount --order=$ORDER --require_symbols=false train.far > pos.cnt
		ngrammake --method=${METHOD[$i]} pos.cnt > pos.lm

		#Removes any existing file named out.txt as the output of this is appended in that file.
		rm -f out.txt
		echo "  Testing trained model on test data..."

		#Iterate over all exiting files that were extracted earlier from test.far
		for file in ./POS_tag_test.txt-*; 
		do 
			#Applies the trained model on the test file and retrieves the best tag and outputs to test.txt
			fstcompose $file train.fst | fstcompose - pos.lm | fstrmepsilon | fstshortestpath | fsttopsort | fstprint --isymbols=input.lex --osymbols=output.lex > test.txt;
			#The results are then appended to the out.txt file. So that all results are together
			cat test.txt |awk '{OFS="\t"; print $3,$4}' >> out.txt
		done
		#combines the already tagged test data with the tag obtained frmo the model into a single file result.txt
		paste <(awk '{OFS="\t"; print $1,$2}' NLSPARQL.test.data ) <(awk '{print $2}' out.txt) > result.txt
		echo "  Evaluating results..."
		#The obtained results are evaluated using the script file conlleval.pl
		perl conlleval.pl -d '\t' < result.txt > ${METHOD[$i]}_$ORDER.txt
		#A separate file which stores the result of each methof with the ngram_order used is maintained
		cat ${METHOD[$i]}_$ORDER.txt | head -2 | tail -1 >> accuracy.data
	done
done
find . -not -name "readme.txt" | rm TOK* *.txt tokens* *.lex *.fst ./POS* *.far pos*
