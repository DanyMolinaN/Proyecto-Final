package Market::Concepts::PriceCondition;

use strict;
use warnings;

# Esta clase evalua condiciones de precio (is_below_eql, is_above_eqh, etc)
# contra los niveles de estructura y liquidez MAS RECIENTES (los ultimos formados).
# Referencia usada:
# - EQL/EQH: el ultimo eq_level de liquidez cuyo second_index sea anterior o igual al indice actual.
# - SH/SL: el ultimo swing_high / swing_low en los external_swings de la estructura.

sub new {
    my ($class, %args) = @_;
    my $self = {
        %args,
    };
    bless $self, $class;
    return $self;
}

sub evaluate {
    my ($self, $market_data, $structure_data, $liquidity_data, $current_index) = @_;
    return {} unless $market_data && defined $current_index;

    my $current_candle = $market_data->get_candle($current_index);
    return {} unless $current_candle;

    my $close_price = $current_candle->{close};

    my %conditions = (
        is_above_eqh => 0,
        is_below_eql => 0,
        is_above_swing_high => 0,
        is_below_swing_low  => 0,
        ref_eqh => undef,
        ref_eql => undef,
        ref_sh  => undef,
        ref_sl  => undef,
    );

    if ($liquidity_data && $liquidity_data->{eq_levels}) {
        my $last_eqh;
        my $last_eql;
        for my $eq (@{ $liquidity_data->{eq_levels} }) {
            next unless defined $eq->{second_index} && $eq->{second_index} <= $current_index;
            if (($eq->{type} || '') eq 'EQH') {
                $last_eqh = $eq if !$last_eqh || $eq->{second_index} > $last_eqh->{second_index};
            }
            elsif (($eq->{type} || '') eq 'EQL') {
                $last_eql = $eq if !$last_eql || $eq->{second_index} > $last_eql->{second_index};
            }
        }
        if ($last_eqh && defined $last_eqh->{level}) {
            $conditions{ref_eqh} = $last_eqh->{level};
            $conditions{is_above_eqh} = 1 if $close_price > $last_eqh->{level};
        }
        if ($last_eql && defined $last_eql->{level}) {
            $conditions{ref_eql} = $last_eql->{level};
            $conditions{is_below_eql} = 1 if $close_price < $last_eql->{level};
        }
    }

    if ($structure_data && $structure_data->{external_swings}) {
        my $last_sh;
        my $last_sl;
        for my $sw (@{ $structure_data->{external_swings} }) {
            next unless defined $sw->{index} && $sw->{index} <= $current_index;
            if (($sw->{kind} || '') eq 'high') {
                $last_sh = $sw if !$last_sh || $sw->{index} > $last_sh->{index};
            }
            elsif (($sw->{kind} || '') eq 'low') {
                $last_sl = $sw if !$last_sl || $sw->{index} > $last_sl->{index};
            }
        }
        if ($last_sh && defined $last_sh->{price}) {
            $conditions{ref_sh} = $last_sh->{price};
            $conditions{is_above_swing_high} = 1 if $close_price > $last_sh->{price};
        }
        if ($last_sl && defined $last_sl->{price}) {
            $conditions{ref_sl} = $last_sl->{price};
            $conditions{is_below_swing_low} = 1 if $close_price < $last_sl->{price};
        }
    }

    return \%conditions;
}

1;
