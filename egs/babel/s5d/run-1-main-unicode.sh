#!/bin/bash

# This is not necessarily the top-level run.sh as it is in other directories.   see README.txt first.
tri5_only=false
sgmm5_only=false
denlats_only=false
data_only=false
morfessor=true
tag_percentage=0.1

[ ! -f ./lang.conf ] && echo 'Language configuration does not exist! Use the configurations in conf/lang/* as a startup' && exit 1
[ ! -f ./conf/common_vars.sh ] && echo 'the file conf/common_vars.sh does not exist!' && exit 1

. conf/common_vars.sh || exit 1;
. ./lang.conf || exit 1;

[ -f local.conf ] && . ./local.conf

. ./utils/parse_options.sh

set -e           #Exit on non-zero return code from any command
set -o pipefail  #Exit if any of the commands in the pipeline will
                 #return non-zero return code
#set -u           #Fail on an undefined variable

lexicon=data/local/lexicon.txt
if $extend_lexicon; then
  lexicon=data/local/lexiconp.txt
fi

./local/check_tools.sh || exit 1

#Preparing dev2h and train directories
if [ ! -f data/raw_train_data/.done ]; then
    echo ---------------------------------------------------------------------
    echo "Subsetting the TRAIN set"
    echo ---------------------------------------------------------------------

    local/make_corpus_subset.sh "$train_data_dir" "$train_data_list" ./data/raw_train_data
    train_data_dir=`utils/make_absolute.sh ./data/raw_train_data`
    touch data/raw_train_data/.done
fi
nj_max=`cat $train_data_list | wc -l`
if [[ "$nj_max" -lt "$train_nj" ]] ; then
    echo "The maximum reasonable number of jobs is $nj_max (you have $train_nj)! (The training and decoding process has file-granularity)"
    exit 1;
    train_nj=$nj_max
fi
train_data_dir=`utils/make_absolute.sh ./data/raw_train_data`

if [ ! -d data/raw_dev10h_data ]; then
  echo ---------------------------------------------------------------------
  echo "Subsetting the DEV10H set"
  echo ---------------------------------------------------------------------
  local/make_corpus_subset.sh "$dev10h_data_dir" "$dev10h_data_list" ./data/raw_dev10h_data || exit 1
fi


mkdir -p data/local
if [[ ! -f $lexicon || $lexicon -ot "$lexicon_file" ]]; then
  echo ---------------------------------------------------------------------
  echo "Preparing lexicon in data/local on" `date`
  echo ---------------------------------------------------------------------

  local/lexicon/make_word_list.py $train_data_dir/filelist.list $train_data_dir/transcription data/local/word_list.txt
  echo -e "<silence> SIL\n<unk> <oov>\n<noise> <sss>\n<v-noise> <vns>" > data/local/nonspeech.txt
  echo -e "<hes> <hes>" > data/local/extraspeech.txt

  fmt="word_list"
  if $morfessor; then
    fmt="morfessor"
    morfessor-train --encoding=utf_8 --traindata-list -f"-_" -s data/local/morfessor.bin \
      data/local/word_list.txt
    morfessor-segment --encoding=utf_8 --output-format-separator '.' --viterbi-maxlen 3 \
      -l data/local/morfessor.bin <(cut -d' ' -f2 data/local/word_list.txt) \
      | sed 's/\.[\_\-]\././g' > data/local/segments
    cut -d' ' data/local/word_list.txt -f2 | paste -d' ' - data/local/segments > data/local/word_list_tmp.txt
    mv data/local/word_list_tmp.txt data/local/word_list.txt
  fi

  local/lexicon/make_unicode_lexicon.py --tag_percentage $tag_percentage --fmt $fmt \
    --nonspeech data/local/nonspeech.txt --extraspeech data/local/extraspeech.txt \
    --verbose data/local/word_list.txt data/local/lexicon.txt data/local/
  local/prepare_unicode_lexicon.py --nonspeech data/local/nonspeech.txt \
    --extraspeech data/local/extraspeech.txt data/local/lexicon_table.txt data/local
  cp data/local/lexicon.txt data/local/filtered_lexicon.txt
fi

mkdir -p data/lang
if [[ ! -f data/lang/L.fst || data/lang/L.fst -ot $lexicon ]]; then
  echo ---------------------------------------------------------------------
  echo "Creating L.fst etc in data/lang on" `date`
  echo ---------------------------------------------------------------------
  utils/prepare_lang.sh \
    --share-silence-phones true \
    data/local $oovSymbol data/local/tmp.lang data/lang
fi

if [[ ! -f data/train/wav.scp || data/train/wav.scp -ot "$train_data_dir" ]]; then
  echo ---------------------------------------------------------------------
  echo "Preparing acoustic training lists in data/train on" `date`
  echo ---------------------------------------------------------------------
  mkdir -p data/train
  local/prepare_acoustic_training_data.pl \
    --vocab $lexicon --fragmentMarkers \-\*\~ \
    $train_data_dir data/train > data/train/skipped_utts.log
fi

if [[ ! -f data/srilm/lm.gz || data/srilm/lm.gz -ot data/train/text ]]; then
  echo ---------------------------------------------------------------------
  echo "Training SRILM language models on" `date`
  echo ---------------------------------------------------------------------
  local/train_lms_srilm.sh  --oov-symbol "$oovSymbol"\
    --train-text data/train/text data data/srilm
fi

if [[ ! -f data/lang/G.fst || data/lang/G.fst -ot data/srilm/lm.gz ]]; then
  echo ---------------------------------------------------------------------
  echo "Creating G.fst on " `date`
  echo ---------------------------------------------------------------------
  local/arpa2G.sh data/srilm/lm.gz data/lang data/lang
fi

echo ---------------------------------------------------------------------
echo "Starting plp feature extraction for data/train in plp on" `date`
echo ---------------------------------------------------------------------

if [ ! -f data/train/.plp.done ]; then
  if $use_pitch; then
    steps/make_plp_pitch.sh --cmd "$train_cmd" --nj $train_nj data/train exp/make_plp_pitch/train plp
  else
    steps/make_plp.sh --cmd "$train_cmd" --nj $train_nj data/train exp/make_plp/train plp
  fi
  utils/fix_data_dir.sh data/train
  steps/compute_cmvn_stats.sh data/train exp/make_plp/train plp
  utils/fix_data_dir.sh data/train
  touch data/train/.plp.done
fi

mkdir -p exp

if [ ! -f data/train_sub3/.done ]; then
  echo ---------------------------------------------------------------------
  echo "Subsetting monophone training data in data/train_sub[123] on" `date`
  echo ---------------------------------------------------------------------
  numutt=`cat data/train/feats.scp | wc -l`;
  utils/subset_data_dir.sh data/train  5000 data/train_sub1
  if [ $numutt -gt 10000 ] ; then
    utils/subset_data_dir.sh data/train 10000 data/train_sub2
  else
    (cd data; ln -s train train_sub2 )
  fi
  if [ $numutt -gt 20000 ] ; then
    utils/subset_data_dir.sh data/train 20000 data/train_sub3
  else
    (cd data; ln -s train train_sub3 )
  fi

  touch data/train_sub3/.done
fi

if $data_only; then
  echo "--data-only is true" && exit 0
fi

if [ ! -f exp/mono/.done ]; then
  echo ---------------------------------------------------------------------
  echo "Starting (small) monophone training in exp/mono on" `date`
  echo ---------------------------------------------------------------------
  steps/train_mono.sh \
    --boost-silence $boost_sil --nj 8 --cmd "$train_cmd" \
    data/train_sub1 data/lang exp/mono
  touch exp/mono/.done
fi

if [ ! -f exp/tri1/.done ]; then
  echo ---------------------------------------------------------------------
  echo "Starting (small) triphone training in exp/tri1 on" `date`
  echo ---------------------------------------------------------------------
  steps/align_si.sh \
    --boost-silence $boost_sil --nj 12 --cmd "$train_cmd" \
    data/train_sub2 data/lang exp/mono exp/mono_ali_sub2

  steps/train_deltas.sh \
    --boost-silence $boost_sil --cmd "$train_cmd" $numLeavesTri1 $numGaussTri1 \
    data/train_sub2 data/lang exp/mono_ali_sub2 exp/tri1

  touch exp/tri1/.done
fi


echo ---------------------------------------------------------------------
echo "Starting (medium) triphone training in exp/tri2 on" `date`
echo ---------------------------------------------------------------------
if [ ! -f exp/tri2/.done ]; then
  steps/align_si.sh \
    --boost-silence $boost_sil --nj 24 --cmd "$train_cmd" \
    data/train_sub3 data/lang exp/tri1 exp/tri1_ali_sub3

  steps/train_deltas.sh \
    --boost-silence $boost_sil --cmd "$train_cmd" $numLeavesTri2 $numGaussTri2 \
    data/train_sub3 data/lang exp/tri1_ali_sub3 exp/tri2

  local/reestimate_langp.sh --cmd "$train_cmd" --unk "$oovSymbol" \
    data/train_sub3 data/lang data/local/ \
    exp/tri2 data/local/dictp/tri2 data/local/langp/tri2 data/langp/tri2

  touch exp/tri2/.done
fi

echo ---------------------------------------------------------------------
echo "Starting (full) triphone training in exp/tri3 on" `date`
echo ---------------------------------------------------------------------
if [ ! -f exp/tri3/.done ]; then
  steps/align_si.sh \
    --boost-silence $boost_sil --nj $train_nj --cmd "$train_cmd" \
    data/train data/langp/tri2 exp/tri2 exp/tri2_ali

  steps/train_deltas.sh \
    --boost-silence $boost_sil --cmd "$train_cmd" \
    $numLeavesTri3 $numGaussTri3 data/train data/langp/tri2 exp/tri2_ali exp/tri3

  local/reestimate_langp.sh --cmd "$train_cmd" --unk "$oovSymbol" \
    data/train data/lang data/local/ \
    exp/tri3 data/local/dictp/tri3 data/local/langp/tri3 data/langp/tri3

  touch exp/tri3/.done
fi

echo ---------------------------------------------------------------------
echo "Starting (lda_mllt) triphone training in exp/tri4 on" `date`
echo ---------------------------------------------------------------------
if [ ! -f exp/tri4/.done ]; then
  steps/align_si.sh \
    --boost-silence $boost_sil --nj $train_nj --cmd "$train_cmd" \
    data/train data/langp/tri3 exp/tri3 exp/tri3_ali

  steps/train_lda_mllt.sh \
    --boost-silence $boost_sil --cmd "$train_cmd" \
    $numLeavesMLLT $numGaussMLLT data/train data/langp/tri3 exp/tri3_ali exp/tri4

  local/reestimate_langp.sh --cmd "$train_cmd" --unk "$oovSymbol" \
    data/train data/lang data/local \
    exp/tri4 data/local/dictp/tri4 data/local/langp/tri4 data/langp/tri4

  touch exp/tri4/.done
fi

echo ---------------------------------------------------------------------
echo "Starting (SAT) triphone training in exp/tri5 on" `date`
echo ---------------------------------------------------------------------

if [ ! -f exp/tri5/.done ]; then
  steps/align_si.sh \
    --boost-silence $boost_sil --nj $train_nj --cmd "$train_cmd" \
    data/train data/langp/tri4 exp/tri4 exp/tri4_ali

  steps/train_sat.sh \
    --boost-silence $boost_sil --cmd "$train_cmd" \
    $numLeavesSAT $numGaussSAT data/train data/langp/tri4 exp/tri4_ali exp/tri5

  local/reestimate_langp.sh --cmd "$train_cmd" --unk "$oovSymbol" \
    data/train data/lang data/local \
    exp/tri5 data/local/dictp/tri5 data/local/langp/tri5 data/langp/tri5

  touch exp/tri5/.done
fi


if [ ! -f exp/tri5_ali/.done ]; then
  echo ---------------------------------------------------------------------
  echo "Starting exp/tri5_ali on" `date`
  echo ---------------------------------------------------------------------
  steps/align_fmllr.sh \
    --boost-silence $boost_sil --nj $train_nj --cmd "$train_cmd" \
    data/train data/langp/tri5 exp/tri5 exp/tri5_ali

  local/reestimate_langp.sh --cmd "$train_cmd" --unk "$oovSymbol" \
    data/train data/lang data/local \
    exp/tri5_ali data/local/dictp/tri5_ali data/local/langp/tri5_ali data/langp/tri5_ali

  touch exp/tri5_ali/.done
fi

if [ ! -f data/langp_test/.done ]; then
  cp -R data/langp/tri5_ali/ data/langp_test
  cp data/lang/G.fst data/langp_test
  touch data/langp_test/.done
fi

if $tri5_only ; then
  echo "Exiting after stage TRI5, as requested. "
  echo "Everything went fine. Done"
  exit 0;
fi

################################################################################
# Ready to start SGMM training
################################################################################

if [ ! -f exp/ubm5/.done ]; then
  echo ---------------------------------------------------------------------
  echo "Starting exp/ubm5 on" `date`
  echo ---------------------------------------------------------------------
  steps/train_ubm.sh \
    --cmd "$train_cmd" $numGaussUBM \
    data/train data/langp/tri5_ali exp/tri5_ali exp/ubm5
  touch exp/ubm5/.done
fi

if [ ! -f exp/sgmm5/.done ]; then
  echo ---------------------------------------------------------------------
  echo "Starting exp/sgmm5 on" `date`
  echo ---------------------------------------------------------------------
  steps/train_sgmm2.sh \
    --cmd "$train_cmd" $numLeavesSGMM $numGaussSGMM \
    data/train data/langp/tri5_ali exp/tri5_ali exp/ubm5/final.ubm exp/sgmm5
  #steps/train_sgmm2_group.sh \
  #  --cmd "$train_cmd" "${sgmm_group_extra_opts[@]-}" $numLeavesSGMM $numGaussSGMM \
  #  data/train data/lang exp/tri5_ali exp/ubm5/final.ubm exp/sgmm5
  touch exp/sgmm5/.done
fi

if $sgmm5_only ; then
  echo "Exiting after stage SGMM5, as requested. "
  echo "Everything went fine. Done"
  exit 0;
fi
################################################################################
# Ready to start discriminative SGMM training
################################################################################

if [ ! -f exp/sgmm5_ali/.done ]; then
  echo ---------------------------------------------------------------------
  echo "Starting exp/sgmm5_ali on" `date`
  echo ---------------------------------------------------------------------
  steps/align_sgmm2.sh \
    --nj $train_nj --cmd "$train_cmd" --transform-dir exp/tri5_ali \
    --use-graphs true --use-gselect true \
    data/train data/lang exp/sgmm5 exp/sgmm5_ali

  local/reestimate_langp.sh --cmd "$train_cmd" --unk "$oovSymbol" \
    data/train data/lang data/local \
    exp/sgmm5_ali data/local/dictp/sgmm5 data/local/langp/sgmm5 data/langp/sgmm5

  touch exp/sgmm5_ali/.done
fi


if [ ! -f exp/sgmm5_denlats/.done ]; then
  echo ---------------------------------------------------------------------
  echo "Starting exp/sgmm5_denlats on" `date`
  echo ---------------------------------------------------------------------
  steps/make_denlats_sgmm2.sh \
    --nj $train_nj --sub-split $train_nj "${sgmm_denlats_extra_opts[@]}" \
    --beam 10.0 --lattice-beam 6 --cmd "$decode_cmd" --transform-dir exp/tri5_ali \
    data/train data/langp/sgmm5 exp/sgmm5_ali exp/sgmm5_denlats
  touch exp/sgmm5_denlats/.done
fi


if $denlats_only ; then
  echo "Exiting after generating denlats, as requested. "
  echo "Everything went fine. Done"
  exit 0;
fi


if [ ! -f exp/sgmm5_mmi_b0.1/.done ]; then
  echo ---------------------------------------------------------------------
  echo "Starting exp/sgmm5_mmi_b0.1 on" `date`
  echo ---------------------------------------------------------------------
  steps/train_mmi_sgmm2.sh \
    --cmd "$train_cmd" "${sgmm_mmi_extra_opts[@]}" \
    --drop-frames true --transform-dir exp/tri5_ali --boost 0.1 \
    data/train data/langp/sgmm5 exp/sgmm5_ali exp/sgmm5_denlats \
    exp/sgmm5_mmi_b0.1
  touch exp/sgmm5_mmi_b0.1/.done
fi

echo ---------------------------------------------------------------------
echo "Finished successfully on" `date`
echo ---------------------------------------------------------------------

exit 0