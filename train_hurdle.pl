#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib $Bin;
use File::Spec;
use Carp qw(carp croak);
use JSON::PP;

use Market::Concepts::DSVWAP::Ridge;

my $OUT_DIR     = File::Spec->catfile($Bin, 'output');
my $TRAIN_NORM  = File::Spec->catfile($OUT_DIR, 'train_features_normalized.csv');
my $TEST_NORM   = File::Spec->catfile($OUT_DIR, 'test_features_normalized.csv');
my $MODELS_JSON = File::Spec->catfile($OUT_DIR, 'models.json');

my @TARGETS = qw(trails_3m trails_5m trails_10m trails_15m);
my @LAMBDAS = (0.01, 0.1, 1, 10, 50, 100);
my @THRESHOLDS = map { $_ / 100 } (5 .. 95); # 0.05 to 0.95 in 0.01 steps

my %DROP_COLS = map { $_ => 1 } qw(
    eq_above_pip_1m  eq_below_pip_1m
    eq_above_pip_10m eq_below_pip_10m
    eq_above_pip_1h  eq_below_pip_1h
    eq_above_kind_1m  eq_below_kind_1m
    eq_above_kind_10m eq_below_kind_10m
    eq_above_kind_1h  eq_below_kind_1h
);

sub read_csv {
    my ($path) = @_;
    open my $fh, '<', $path or croak "No puedo abrir '$path': $!";
    my $hdr = <$fh>; chomp $hdr; $hdr =~ s/\r//g;
    my @headers = split /,/, $hdr;
    my @rows;
    while (<$fh>) {
        chomp; s/\r//g;
        next unless /\S/;
        my @v = split /,/, $_, -1;
        my %row; @row{@headers} = @v;
        push @rows, \%row;
    }
    close $fh;
    return (\@headers, \@rows);
}

sub is_num {
    my ($v) = @_;
    return 0 unless defined $v;
    $v =~ s/^\s+|\s+$//g;
    return $v =~ /^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$/;
}

sub build_X {
    my ($rows, $base_num, $missing_set, $cat_map) = @_;
    my @missing_cols = sort keys %$missing_set;
    my @cat_cols_ord = sort keys %$cat_map;
    my @X;
    for my $row (@$rows) {
        my @x = (1);
        for my $col (@$base_num) {
            my $v = $row->{$col} // ''; $v =~ s/^\s+|\s+$//g;
            push @x, is_num($v) ? $v + 0 : 0;
        }
        for my $col (@missing_cols) {
            my $v = $row->{$col} // ''; $v =~ s/^\s+|\s+$//g;
            push @x, is_num($v) ? 0 : 1;
        }
        for my $col (@cat_cols_ord) {
            my $val = $row->{$col} // ''; $val =~ s/^\s+|\s+$//g;
            for my $cat (@{$cat_map->{$col}}) {
                push @x, ($val eq $cat) ? 1 : 0;
            }
        }
        push @X, \@x;
    }
    return \@X;
}

sub calc_f1 {
    my ($preds_prob, $actual, $thresh) = @_;
    my ($tp, $fp, $fn, $tn) = (0, 0, 0, 0);
    for my $i (0 .. $#$actual) {
        my $p = ($preds_prob->[$i] >= $thresh) ? 1 : 0;
        my $a = $actual->[$i];
        if ($p == 1 && $a == 1) { $tp++; }
        elsif ($p == 1 && $a == 0) { $fp++; }
        elsif ($p == 0 && $a == 1) { $fn++; }
        else { $tn++; }
    }
    my $prec = ($tp + $fp) > 0 ? $tp / ($tp + $fp) : 0;
    my $rec  = ($tp + $fn) > 0 ? $tp / ($tp + $fn) : 0;
    my $f1   = ($prec + $rec) > 0 ? 2 * $prec * $rec / ($prec + $rec) : 0;
    return ($f1, $prec, $rec, $tp, $fp, $fn, $tn);
}

sub mae_rmse {
    my ($pred, $actual) = @_;
    my $n = scalar @$pred;
    my $sum_abs = 0; my $sum_sq = 0;
    for my $i (0 .. $n-1) {
        my $d = $pred->[$i] - $actual->[$i];
        $sum_abs += abs($d);
        $sum_sq += $d * $d;
    }
    return ($sum_abs/$n, sqrt($sum_sq/$n));
}

my ($train_hdrs, $train_rows) = read_csv($TRAIN_NORM);
my ($test_hdrs,  $test_rows)  = read_csv($TEST_NORM);

my %is_target = map { $_ => 1 } @TARGETS;
my (@num_cols, @cat_cols_list);
for my $col (@$train_hdrs) {
    next if $DROP_COLS{$col} || $is_target{$col};
    if ($col =~ /kind/) { push @cat_cols_list, $col; }
    else                { push @num_cols, $col; }
}

my %missing_set;
for my $col (@num_cols) {
    for my $row (@$train_rows) {
        my $v = $row->{$col} // ''; $v =~ s/^\s+|\s+$//g;
        unless (is_num($v)) { $missing_set{$col} = 1; last; }
    }
}

my %cat_map;
for my $col (@cat_cols_list) {
    my %uniq;
    for my $row (@$train_rows) {
        my $v = $row->{$col} // ''; $v =~ s/^\s+|\s+$//g;
        $uniq{$v} = 1 if $v ne '';
    }
    $cat_map{$col} = [sort keys %uniq];
}

my $X_train = build_X($train_rows, \@num_cols, \%missing_set, \%cat_map);
my $X_test  = build_X($test_rows,  \@num_cols, \%missing_set, \%cat_map);
my $p = scalar @{$X_train->[0]};

# Extraer targets crudos y binarios
my (%Y_train, %Y_test, %Y_train_bin, %Y_test_bin);
for my $tgt (@TARGETS) {
    $Y_train{$tgt} = [map { $_->{$tgt} + 0 } @$train_rows];
    $Y_test{$tgt}  = [map { $_->{$tgt} + 0 } @$test_rows];
    $Y_train_bin{$tgt} = [map { $_ > 0 ? 1 : 0 } @{$Y_train{$tgt}}];
    $Y_test_bin{$tgt}  = [map { $_ > 0 ? 1 : 0 } @{$Y_test{$tgt}}];
}

print "=== PASO 1: Targets Binarios ===\n";
for my $tgt (@TARGETS) {
    my $sum_tr = 0; $sum_tr += $_ for @{$Y_train_bin{$tgt}};
    my $sum_te = 0; $sum_te += $_ for @{$Y_test_bin{$tgt}};
    printf "%-12s Train: %.2f%% (1s) | Test: %.2f%% (1s)\n",
        $tgt, 100*$sum_tr/scalar(@$train_rows), 100*$sum_te/scalar(@$test_rows);
}

my $n_train = scalar @$X_train;
my $n_subtrain = int($n_train * 0.8);
my @X_sub = @{$X_train}[0 .. $n_subtrain - 1];
my @X_val = @{$X_train}[$n_subtrain .. $n_train - 1];
my $XtX_sub = Market::Concepts::DSVWAP::Ridge->compute_XtX(\@X_sub);
my $XtX_full = Market::Concepts::DSVWAP::Ridge->compute_XtX($X_train);

my %clf_models;

print "\n=== PASO 2: Entrenar Clasificador (Parte A) ===\n";
for my $tgt (@TARGETS) {
    my @y_sub = @{$Y_train_bin{$tgt}}[0 .. $n_subtrain - 1];
    my @y_val = @{$Y_train_bin{$tgt}}[$n_subtrain .. $n_train - 1];
    my $Xty_sub = Market::Concepts::DSVWAP::Ridge->compute_Xty(\@X_sub, \@y_sub);

    my ($best_f1, $best_lam, $best_thr) = (-1, undef, undef);
    
    for my $lam (@LAMBDAS) {
        my $beta = Market::Concepts::DSVWAP::Ridge->solve_ridge($XtX_sub, $Xty_sub, $lam, $p);
        next unless defined $beta;
        my $preds_val = Market::Concepts::DSVWAP::Ridge->ridge_predict(\@X_val, $beta);
        
        for my $thr (@THRESHOLDS) {
            my ($f1, $prec, $rec) = calc_f1($preds_val, \@y_val, $thr);
            if ($f1 > $best_f1) {
                $best_f1 = $f1; $best_lam = $lam; $best_thr = $thr;
            }
        }
    }
    
    $best_lam //= 100;
    $best_thr //= 0.5;
    
    my $Xty_full = Market::Concepts::DSVWAP::Ridge->compute_Xty($X_train, $Y_train_bin{$tgt});
    my $beta_full = Market::Concepts::DSVWAP::Ridge->solve_ridge($XtX_full, $Xty_full, $best_lam, $p);
    
    $clf_models{$tgt} = { lam => $best_lam, thr => $best_thr, beta => $beta_full };
    printf "%-12s Lambda=%-5s Umbral=%.2f F1_val_opt=%.4f\n", $tgt, $best_lam, $best_thr, $best_f1;
}

print "\n=== PASO 3 & 4: Ensamblar Hurdle y Evaluar en Test ===\n";

# Cargar Ridge magnitud (Fase 4 puro)
open my $fj, '<', $MODELS_JSON or croak $!;
my $json_text = do { local $/; <$fj> };
close $fj;
my $ridge_models = JSON::PP->new->utf8->decode($json_text);

my %hurdle_raw;
my %ridge_pure_raw;
for my $tgt (@TARGETS) {
    my $clf_beta = $clf_models{$tgt}{beta};
    my $clf_thr  = $clf_models{$tgt}{thr};
    my $mag_beta = $ridge_models->{$tgt}{beta};
    
    my $clf_preds = Market::Concepts::DSVWAP::Ridge->ridge_predict($X_test, $clf_beta);
    my $mag_preds = Market::Concepts::DSVWAP::Ridge->ridge_predict($X_test, $mag_beta);
    
    $ridge_pure_raw{$tgt} = $mag_preds;
    
    my ($f1, $prec, $rec, $tp, $fp, $fn, $tn) = calc_f1($clf_preds, $Y_test_bin{$tgt}, $clf_thr);
    printf "\n[Clasificador $tgt] F1=%.4f Prec=%.4f Rec=%.4f | CM: TP=%d FP=%d FN=%d TN=%d\n",
        $f1, $prec, $rec, $tp, $fp, $fn, $tn;
        
    my @h_preds;
    for my $i (0 .. $#$X_test) {
        if ($clf_preds->[$i] >= $clf_thr) {
            my $val = int($mag_preds->[$i] + 0.5); # round
            $val = 1 if $val < 1; # max(1, round)
            push @h_preds, $val;
        } else {
            push @h_preds, 0;
        }
    }
    $hurdle_raw{$tgt} = \@h_preds;
}

my ($h3, $h5, $h10, $h15, $v_h) = Market::Concepts::DSVWAP::Ridge->postprocess_predictions(
    $hurdle_raw{trails_3m}, $hurdle_raw{trails_5m}, $hurdle_raw{trails_10m}, $hurdle_raw{trails_15m}
);
my %hurdle_final = (trails_3m=>$h3, trails_5m=>$h5, trails_10m=>$h10, trails_15m=>$h15);

my ($r3, $r5, $r10, $r15, $v_r) = Market::Concepts::DSVWAP::Ridge->postprocess_predictions(
    $ridge_pure_raw{trails_3m}, $ridge_pure_raw{trails_5m}, $ridge_pure_raw{trails_10m}, $ridge_pure_raw{trails_15m}
);
my %ridge_final = (trails_3m=>$r3, trails_5m=>$r5, trails_10m=>$r10, trails_15m=>$r15);

print "\n[Métricas Finales - MAE / RMSE]\n";
printf "%-12s | %-20s | %-20s | %-20s | %-20s\n", "Target", "Hurdle", "Ridge Puro", "Base A (Cero)", "Base B (Media)";
for my $tgt (@TARGETS) {
    my ($mae_h, $rmse_h) = mae_rmse($hurdle_final{$tgt}, $Y_test{$tgt});
    my ($mae_r, $rmse_r) = mae_rmse($ridge_final{$tgt}, $Y_test{$tgt});
    my ($mae_A, $rmse_A) = mae_rmse([map {0} @{$Y_test{$tgt}}], $Y_test{$tgt});
    
    my $sum_tr = 0; $sum_tr += $_ for @{$Y_train{$tgt}};
    my $mean_tr = $sum_tr / scalar(@{$Y_train{$tgt}});
    my ($mae_B, $rmse_B) = mae_rmse([map {$mean_tr} @{$Y_test{$tgt}}], $Y_test{$tgt});
    
    printf "%-12s | %6.4f / %6.4f | %6.4f / %6.4f | %6.4f / %6.4f | %6.4f / %6.4f\n",
        $tgt, $mae_h, $rmse_h, $mae_r, $rmse_r, $mae_A, $rmse_A, $mae_B, $rmse_B;
}
