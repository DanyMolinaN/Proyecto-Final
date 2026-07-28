package Market::Concepts::DSVWAP::GhostTrailPredictor;

use strict;
use warnings;
use File::Spec;
use JSON::PP;
use Carp qw(croak carp);

use Market::Concepts::DSVWAP::Ridge;
use Market::Concepts::DSVWAP::LiquiditySnapshot;
use Market::Indicators::ATR;
use Market::Indicators::EMA;

sub new {
    my ($class, %args) = @_;
    my $self = bless {
        models_path      => $args{models_path},
        norm_params_path => $args{norm_params_path},
        pip_factor       => $args{pip_factor} // 4,
        window_1m        => $args{window_1m}  // 500,
        window_10m       => $args{window_10m} // 300,
        _feat_names      => undef,
        _betas           => undef,
        _norm_params     => undef,
        _missing_cols    => undef,
        _cat_cols        => undef,
        _base_num_cols   => undef,
        _atr_vals        => undef,
        _ema9_vals       => undef,
        _snapshot_engine => undef,
    }, $class;
    $self->_load_models()          if $args{models_path};
    $self->_load_normalization()   if $args{norm_params_path};
    return $self;
}

# --- Carga de modelos (UNA VEZ al iniciar) ---
sub _load_models {
    my ($self) = @_;
    my $path = $self->{models_path};
    return unless $path && -f $path;

    local $/;
    open my $fh, '<', $path or croak "GhostTrailPredictor: no puedo abrir '$path': $!";
    my $json = JSON::PP->new->utf8->decode(<$fh>);
    close $fh;

    $self->{_feat_names} = $json->{feature_columns} || [];
    croak "GhostTrailPredictor: feature_columns vacio en $path"
        unless @{$self->{_feat_names}} > 0;

    my %betas;
    for my $tgt (qw(trails_3m trails_5m trails_10m trails_15m)) {
        next unless $json->{$tgt} && ref $json->{$tgt} eq 'HASH';
        $betas{$tgt} = $json->{$tgt}{beta};
    }
    $self->{_betas} = \%betas;

    $self->_classify_features();
}

sub _classify_features {
    my ($self) = @_;
    my @feat = @{$self->{_feat_names}};

    # feat[0] = intercept, feat[1..] = features
    my (@base_num, @missing_flags, %cat_map);
    for my $i (1 .. $#feat) {
        my $name = $feat[$i];
        if ($name =~ /_missing$/) {
            push @missing_flags, $name;
        }
        elsif ($name =~ /_(BOS|CHoCH|NONE)$/) {
            my $cat_col = $name;
            $cat_col =~ s/_(BOS|CHoCH|NONE)$//;
            push @{$cat_map{$cat_col}}, $name;
        }
        else {
            push @base_num, $name;
        }
    }

    $self->{_base_num_cols}  = \@base_num;
    $self->{_missing_cols}   = \@missing_flags;
    $self->{_cat_cols}       = \%cat_map;
}

sub _load_normalization {
    my ($self) = @_;
    my $path = $self->{norm_params_path};
    return unless $path && -f $path;

    local $/;
    open my $fh, '<', $path or croak "GhostTrailPredictor: no puedo abrir '$path': $!";
    $self->{_norm_params} = JSON::PP->new->utf8->decode(<$fh>);
    close $fh;
}

sub precompute_indicators {
    my ($self, $market_data) = @_;
    return unless $market_data && $market_data->can('size') && $market_data->size() > 0;

    my $n = $market_data->size();
    my $atr = Market::Indicators::ATR->new(14);
    my $ema = Market::Indicators::EMA->new(9, field => 'volume');
    my (@atr_vals, @ema_vals);

    for my $i (0 .. $n - 1) {
        $atr->update_at_index($market_data, $i);
        $ema->update_at_index($market_data, $i);
        push @atr_vals, ($atr->get_values() // [])->[-1];
        push @ema_vals, ($ema->get_values() // [])->[-1];
    }

    $self->{_atr_vals}  = \@atr_vals;
    $self->{_ema9_vals} = \@ema_vals;

    $self->{_snapshot_engine} = Market::Concepts::DSVWAP::LiquiditySnapshot->new(
        pip_factor => $self->{pip_factor},
        window_1m  => $self->{window_1m},
        window_10m => $self->{window_10m},
    );
}

# --- API principal ---
sub predict_at_appearance {
    my ($self, $market_data, $appearance_event) = @_;
    return undef unless $market_data && $appearance_event;

    my $anchor_index = $appearance_event->{anchor_index} // return undef;

    # El ts del GhostTrailEvent es del extremo; necesitamos el ts del ancla.
    my $c = eval { $market_data->get_candle($anchor_index) };
    my $anchor_ts = $c ? $c->{timestamp} : undef;
    return undef unless defined $anchor_ts;

    my $snap = $self->{_snapshot_engine}->snapshot_for_anchor(
        $market_data, $anchor_ts, $anchor_index
    );
    return undef unless $snap;

    my $flat = $self->_flatten_snapshot($snap, $market_data, $anchor_index);
    return undef unless $flat;

    my $X = $self->_build_feature_vector($flat);
    return undef unless $X;

    my %ridge_preds;
    for my $tgt (qw(trails_3m trails_5m trails_10m trails_15m)) {
        my $beta = $self->{_betas}{$tgt} or next;
        my $yhat = 0;
        $yhat += $X->[$_] * $beta->[$_] for 0 .. $#$X;
        $ridge_preds{$tgt} = $yhat;
    }

    my ($f3, $f5, $f10, $f15) = Market::Concepts::DSVWAP::Ridge->postprocess_predictions(
        [$ridge_preds{trails_3m}],  [$ridge_preds{trails_5m}],
        [$ridge_preds{trails_10m}], [$ridge_preds{trails_15m}],
    );

    my $future_available = ($anchor_index + 15 < $market_data->size()) ? 1 : 0;
    my %real;
    if ($future_available) {
        my $gtc = $appearance_event->{_ghost_counter};
        if ($gtc && $gtc->can('count_trails_for_anchor')) {
            my $r = $gtc->count_trails_for_anchor($anchor_index);
            if ($r) {
                %real = (
                    y_3  => $r->{trails_3m},
                    y_5  => $r->{trails_5m},
                    y_10 => $r->{trails_10m},
                    y_15 => $r->{trails_15m},
                );
            }
        }
    }

    return {
        appearance_index => $anchor_index,
        appearance_ts    => $anchor_ts,
        ridge => {
            y_3  => $f3->[0],
            y_5  => $f5->[0],
            y_10 => $f10->[0],
            y_15 => $f15->[0],
        },
        baseline_zero => { y_3 => 0, y_5 => 0, y_10 => 0, y_15 => 0 },
        real => (%real ? \%real : undef),
    };
}

# --- Flatten snapshot to column-name hash ---
sub _flatten_snapshot {
    my ($self, $snap, $market_data, $anchor_index) = @_;
    my %flat;

    my @TFS    = ('1m', '10m', '1h');
    my %TF_KEY = ('1m' => 'tf_1m', '10m' => 'tf_10m', '1h' => 'tf_1h');

    for my $tf (@TFS) {
        my $snap_key = $TF_KEY{$tf};
        my $tfd = $snap->{$snap_key};
        my $suffix = "_${tf}";

        my $empty_val = sub { return undef };
        my $sanitize  = sub {
            my ($v) = @_;
            return undef unless defined $v;
            return undef if "$v" =~ /^[+-]?Inf$/i || "$v" =~ /^NaN$/i;
            return $v;
        };

        unless ($tfd && ref $tfd eq 'HASH') {
            for my $col (qw(ob_above_pip ob_above_thickness_pip
                ob_below_pip ob_below_thickness_pip
                fvg_above_pip fvg_above_size_pip
                fvg_below_pip fvg_below_size_pip
                fib_0_pip fib_236_pip fib_382_pip fib_500_pip
                fib_618_pip fib_786_pip fib_1000_pip
                vwap_pip vwap_u1_pip vwap_l1_pip
                vwap_u2_pip vwap_l2_pip
                vwap_band1_thickness_pip vwap_band2_thickness_pip
                vp_poc_pip vp_vah_pip vp_val_pip vp_va_thickness_pip
                mtf_pdh_pip mtf_pdl_pip mtf_pwh_pip mtf_pwl_pip
                structure_above_pip structure_below_pip
                eq_above_pip eq_below_pip))
            {
                $flat{"${col}${suffix}"} = undef;
            }
            for my $col (qw(structure_above_kind structure_below_kind
                eq_above_kind eq_below_kind))
            {
                $flat{"${col}${suffix}"} = 'NONE';
            }
            next;
        }

        $flat{"ob_above_pip${suffix}"}           = $sanitize->($self->_flat_ob($tfd, 'above'));
        $flat{"ob_above_thickness_pip${suffix}"} = $sanitize->($self->_flat_ob_thick($tfd, 'above'));
        $flat{"ob_below_pip${suffix}"}           = $sanitize->($self->_flat_ob($tfd, 'below'));
        $flat{"ob_below_thickness_pip${suffix}"} = $sanitize->($self->_flat_ob_thick($tfd, 'below'));

        $flat{"fvg_above_pip${suffix}"}          = $sanitize->($self->_flat_fvg($tfd, 'above'));
        $flat{"fvg_above_size_pip${suffix}"}     = $sanitize->($self->_flat_fvg_size($tfd, 'above'));
        $flat{"fvg_below_pip${suffix}"}          = $sanitize->($self->_flat_fvg($tfd, 'below'));
        $flat{"fvg_below_size_pip${suffix}"}     = $sanitize->($self->_flat_fvg_size($tfd, 'below'));

        my $fib = $self->_flat_fib($tfd);
        for my $fk (keys %$fib) {
            $flat{"${fk}${suffix}"} = $sanitize->($fib->{$fk});
        }

        my $v = $tfd->{vwap} || {};
        $flat{"vwap_pip${suffix}"}                = $sanitize->($v->{pip_vwap});
        $flat{"vwap_u1_pip${suffix}"}             = $sanitize->($v->{pip_u1});
        $flat{"vwap_l1_pip${suffix}"}             = $sanitize->($v->{pip_l1});
        $flat{"vwap_u2_pip${suffix}"}             = $sanitize->($v->{pip_u2});
        $flat{"vwap_l2_pip${suffix}"}             = $sanitize->($v->{pip_l2});
        $flat{"vwap_band1_thickness_pip${suffix}"} = $sanitize->($v->{band1_thickness_pip});
        $flat{"vwap_band2_thickness_pip${suffix}"} = $sanitize->($v->{band2_thickness_pip});

        my $vp = $tfd->{vp} || {};
        $flat{"vp_poc_pip${suffix}"}          = $sanitize->($vp->{pip_poc});
        $flat{"vp_vah_pip${suffix}"}          = $sanitize->($vp->{pip_vah});
        $flat{"vp_val_pip${suffix}"}          = $sanitize->($vp->{pip_val});
        $flat{"vp_va_thickness_pip${suffix}"} = $sanitize->($vp->{va_thickness_pip});

        my $mtf = $tfd->{mtf} || {};
        $flat{"mtf_pdh_pip${suffix}"} = $sanitize->($mtf->{pip_pdh});
        $flat{"mtf_pdl_pip${suffix}"} = $sanitize->($mtf->{pip_pdl});
        $flat{"mtf_pwh_pip${suffix}"} = $sanitize->($mtf->{pip_pwh});
        $flat{"mtf_pwl_pip${suffix}"} = $sanitize->($mtf->{pip_pwl});

        my ($st_above_pip, $st_above_kind, $st_below_pip, $st_below_kind)
            = $self->_flat_structure($tfd);
        $flat{"structure_above_pip${suffix}"}  = $sanitize->($st_above_pip);
        $flat{"structure_above_kind${suffix}"} = $st_above_kind // 'NONE';
        $flat{"structure_below_pip${suffix}"}  = $sanitize->($st_below_pip);
        $flat{"structure_below_kind${suffix}"} = $st_below_kind // 'NONE';

        my ($eq_above_pip, $eq_above_kind, $eq_below_pip, $eq_below_kind)
            = $self->_flat_eq($tfd);
        $flat{"eq_above_pip${suffix}"}  = $sanitize->($eq_above_pip);
        $flat{"eq_above_kind${suffix}"} = $eq_above_kind // 'NONE';
        $flat{"eq_below_pip${suffix}"}  = $sanitize->($eq_below_pip);
        $flat{"eq_below_kind${suffix}"} = $eq_below_kind // 'NONE';
    }

    my $ai = $anchor_index // 0;
    $flat{atr_1m}         = $self->{_atr_vals}->[$ai];
    $flat{volume_1m}      = eval { $market_data->get_candle($ai)->{volume} } // undef;
    $flat{ema9_volume_1m} = $self->{_ema9_vals}->[$ai];

    return \%flat;
}

# --- Flatten helpers ---
sub _flat_ob {
    my ($self, $tfd, $side) = @_;
    my $obs = $tfd->{ob} || [];
    my ($best, $best_dist);
    for my $ob (@$obs) {
        next unless ref $ob eq 'HASH';
        my $pip = $ob->{pip_mid_signed} // $ob->{pip_mid};
        next unless defined $pip;
        my $is_above = defined $ob->{pip_mid_signed} ? ($ob->{pip_mid_signed} > 0) : (($ob->{type} // '') =~ /bear/i);
        next if ($side eq 'above') ? !$is_above : $is_above;
        my $dist = abs($pip);
        if (!defined $best_dist || $dist < $best_dist) {
            $best_dist = $dist;
            $best = $pip;
        }
    }
    return $best // $best_dist;
}

sub _flat_ob_thick {
    my ($self, $tfd, $side) = @_;
    my $obs = $tfd->{ob} || [];
    my ($best, $best_dist);
    for my $ob (@$obs) {
        next unless ref $ob eq 'HASH';
        my $pip = $ob->{pip_mid_signed} // $ob->{pip_mid};
        next unless defined $pip;
        my $is_above = defined $ob->{pip_mid_signed} ? ($ob->{pip_mid_signed} > 0) : (($ob->{type} // '') =~ /bear/i);
        next if ($side eq 'above') ? !$is_above : $is_above;
        my $dist = abs($pip);
        if (!defined $best_dist || $dist < $best_dist) {
            $best_dist = $dist;
            $best = $ob->{thickness};
        }
    }
    return defined $best ? $best * $self->{pip_factor} : undef;
}

sub _flat_fvg {
    my ($self, $tfd, $side) = @_;
    my $fvgs = $tfd->{fvg} || [];
    my ($best, $best_dist);
    for my $f (@$fvgs) {
        next unless ref $f eq 'HASH';
        my $pip = $f->{pip_mid_signed} // $f->{pip_mid};
        next unless defined $pip;
        my $is_above = defined $f->{pip_mid_signed} ? ($f->{pip_mid_signed} > 0) : (($f->{type} // '') =~ /bear/i);
        next if ($side eq 'above') ? !$is_above : $is_above;
        my $dist = abs($pip);
        if (!defined $best_dist || $dist < $best_dist) {
            $best_dist = $dist;
            $best = $pip;
        }
    }
    return $best // $best_dist;
}

sub _flat_fvg_size {
    my ($self, $tfd, $side) = @_;
    my $fvgs = $tfd->{fvg} || [];
    my ($best, $best_dist);
    for my $f (@$fvgs) {
        next unless ref $f eq 'HASH';
        my $pip = $f->{pip_mid_signed} // $f->{pip_mid};
        next unless defined $pip;
        my $is_above = defined $f->{pip_mid_signed} ? ($f->{pip_mid_signed} > 0) : (($f->{type} // '') =~ /bear/i);
        next if ($side eq 'above') ? !$is_above : $is_above;
        my $dist = abs($pip);
        if (!defined $best_dist || $dist < $best_dist) {
            $best_dist = $dist;
            $best = $f->{size};
        }
    }
    return defined $best ? $best * $self->{pip_factor} : undef;
}

sub _flat_fib {
    my ($self, $tfd) = @_;
    my $fibs = $tfd->{fib} || [];
    my @COL_NAMES = qw(fib_0_pip fib_236_pip fib_382_pip fib_500_pip
                       fib_618_pip fib_786_pip fib_1000_pip);
    my %out;
    for my $pos (0 .. $#COL_NAMES) {
        my $elem = $fibs->[$pos];
        $out{$COL_NAMES[$pos]} = (defined $elem && ref $elem eq 'HASH') ? $elem->{pip} : undef;
    }
    return \%out;
}

sub _flat_structure {
    my ($self, $tfd) = @_;
    my $events = $tfd->{structure_events} || [];
    my ($above_elem, $below_elem);
    my ($above_dist, $below_dist);
    for my $e (@$events) {
        next unless ref $e eq 'HASH';
        my $pip = $e->{pip};
        next unless defined $pip;
        if ($pip > 0) {
            if (!defined $above_dist || $pip < $above_dist) {
                $above_dist = $pip;
                $above_elem = $e;
            }
        } elsif ($pip < 0) {
            my $abs_pip = abs($pip);
            if (!defined $below_dist || $abs_pip < $below_dist) {
                $below_dist = $abs_pip;
                $below_elem = $e;
            }
        }
    }
    return (
        $above_elem ? $above_elem->{pip} : undef,
        $above_elem ? ($above_elem->{kind} // 'NONE') : 'NONE',
        $below_elem ? $below_elem->{pip} : undef,
        $below_elem ? ($below_elem->{kind} // 'NONE') : 'NONE',
    );
}

sub _flat_eq {
    my ($self, $tfd) = @_;
    my $events = $tfd->{eq_events} || [];
    my ($above_elem, $below_elem);
    my ($above_dist, $below_dist);
    for my $e (@$events) {
        next unless ref $e eq 'HASH';
        my $pip = $e->{pip};
        next unless defined $pip;
        if ($pip > 0) {
            if (!defined $above_dist || $pip < $above_dist) {
                $above_dist = $pip;
                $above_elem = $e;
            }
        } elsif ($pip < 0) {
            my $abs_pip = abs($pip);
            if (!defined $below_dist || $abs_pip < $below_dist) {
                $below_dist = $abs_pip;
                $below_elem = $e;
            }
        }
    }
    return (
        $above_elem ? $above_elem->{pip} : undef,
        $above_elem ? ($above_elem->{kind} // 'NONE') : 'NONE',
        $below_elem ? $below_elem->{pip} : undef,
        $below_elem ? ($below_elem->{kind} // 'NONE') : 'NONE',
    );
}

# --- Construir vector X exactamente como build_X en train_model.pl ---
sub _build_feature_vector {
    my ($self, $flat) = @_;
    my @feat = @{$self->{_feat_names}};
    my @X = (1);

    my $norm = $self->{_norm_params} || {};

    for my $i (1 .. $#feat) {
        my $name = $feat[$i];

        if ($name =~ /_missing$/) {
            my $base_col = $name;
            $base_col =~ s/_missing$//;
            my $val = $flat->{$base_col};
            push @X, (defined $val && "$val" =~ /^-?\d/) ? 0 : 1;
        }
        elsif ($name =~ /_(BOS|CHoCH|NONE)$/) {
            my $cat_col = $name;
            $cat_col =~ s/_(BOS|CHoCH|NONE)$//;
            my $kind = $flat->{$cat_col} // 'NONE';
            my $expected_cat = $1;
            push @X, ($kind eq $expected_cat) ? 1 : 0;
        }
        else {
            my $raw = $flat->{$name};
            if (defined $raw && "$raw" =~ /^-?\d/) {
                my $val = $raw + 0;
                if (exists $norm->{$name}) {
                    $val = ($val - $norm->{$name}{mean}) / $norm->{$name}{std};
                }
                push @X, $val;
            } else {
                push @X, 0;
            }
        }
    }

    return \@X;
}

1;