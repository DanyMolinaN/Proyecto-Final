package Market::Concepts::ZZMTFEngine;

use strict;
use warnings;
use Market::Indicators::ZigZagMTF;

sub new {
    my ($class) = @_;
    my $self = {};
    bless $self, $class;
    return $self;
}

sub calculate {
    my ($self, $market_data, %args) = @_;

    my $overlay_settings = $args{overlay_settings};
    my $in_tf = $overlay_settings ? ($overlay_settings->values()->{zzmtf_internal_tf} || '15m') : '15m';
    my $ex_tf = $overlay_settings ? ($overlay_settings->values()->{zzmtf_external_tf} || '1h') : '1h';

    my %tf_map = ('5m' => 5, '15m' => 15, '30m' => 30, '1h' => 60, '4h' => 240);

    # Configuraciones de mitigacion de ruido (estricto):
    # period=5 para internal (requiere 5 velas agregadas a cada lado)
    # period=10 para external (requiere 10 velas agregadas a cada lado)
    my $zz_in = Market::Indicators::ZigZagMTF->new(resolution_minutes => $tf_map{$in_tf} || 15, period => 5);
    my $zz_ex = Market::Indicators::ZigZagMTF->new(resolution_minutes => $tf_map{$ex_tf} || 60, period => 10);

    my $view_end = $args{view_end};
    my $total = $market_data->size();
    $view_end = $total > 0 ? $total - 1 : -1 if !defined $view_end;

    if ($view_end >= 0) {
        for my $i (0 .. $view_end) {
            $zz_in->update_at_index($market_data, $i);
            $zz_ex->update_at_index($market_data, $i);
        }
    }

    my @in_swings = map {
        my $k = $_->{kind} eq 'H' ? 'high' : 'low';
        +{ %$_, price => $_->{price}, kind => $k, scope => 'internal', type => 'swing', label => ($k eq 'high' ? 'H' : 'L') }
    } @{ $zz_in->get_swings() || [] };

    my @ex_swings = map {
        my $k = $_->{kind} eq 'H' ? 'high' : 'low';
        +{ %$_, price => $_->{price}, kind => $k, scope => 'external', type => 'swing', label => ($k eq 'high' ? 'H' : 'L') }
    } @{ $zz_ex->get_swings() || [] };

    return {
        internal_swings => \@in_swings,
        external_swings => \@ex_swings,
        tentative_in    => $zz_in->get_tentative_segment(),
        tentative_ex    => $zz_ex->get_tentative_segment(),
        metadata        => {
            source => 'ZZMTFEngine'
        }
    };
}

1;
