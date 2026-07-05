#!/usr/bin/env perl
use strict;
use warnings;

package ViewportSim;
sub new { bless { min_edge_bars => 2 }, shift }

sub _min_edge_bars {
    my ($self, $total) = @_;
    my $keep = $self->{min_edge_bars};
    return $total if $total > 0 && $keep > $total;
    return $keep;
}

sub _horizontal_offset_limits {
    my ($self, $visible, $total) = @_;
    return (0, 0) unless $total > 0 && $visible > 0;
    my $keep = $self->_min_edge_bars($total);
    my $min_offset = $keep - $visible;
    $min_offset = 0 if $min_offset > 0;
    my $max_offset = $total - $visible;
    $max_offset = 0 if $max_offset < 0;
    return ($min_offset, $max_offset);
}

sub _offset_at_historical_extreme {
    my ($self, $visible, $total) = @_;
    return 0 unless $total > 0 && $visible > 0;
    return $total - $visible;
}

sub window_at {
    my ($self, $visible, $total, $offset) = @_;
    my ($min_o, $max_o) = $self->_horizontal_offset_limits($visible, $total);
    $offset = $min_o if $offset < $min_o;
    $offset = $max_o if $offset > $max_o;
    my $end_visual = $total - 1 - $offset;
    my $start = $end_visual - $visible + 1;
    my $ds = $start; $ds = 0 if $ds < 0;
    my $de = $end_visual; $de = $total - 1 if $de > $total - 1;
    return {
        offset     => $offset,
        view_start => $start,
        data_start => $ds,
        data_end   => $de,
        data_count => ($de >= $ds ? $de - $ds + 1 : 0),
        min_o      => $min_o,
        max_o      => $max_o,
        hist_o     => $self->_offset_at_historical_extreme($visible, $total),
    };
}

my $sim = ViewportSim->new();
my @cases = (
    [250, 5000, 0,     '1H reciente (offset=0)'],
    [250, 5000, 4750,  '1H historico max'],
    [250, 5000, -248,  '1H futuro min (2 velas)'],
    [131, 131, 0,       '4H todas las velas'],
    [250, 131, 0,       '4H zoom-out reciente'],
    [250, 131, -119,    '4H zoom-out historico'],
);

my $fail = 0;
for my $c (@cases) {
    my ($vis, $tot, $off, $label) = @$c;
    my $w = $sim->window_at($vis, $tot, $off);
    my $last_slot = $w->{data_end} - $w->{view_start};
    my $first_slot = $w->{data_start} - $w->{view_start};
    my @issues;

    if ($off == 0 && $vis <= $tot) {
        push @issues, 'reciente: ultima vela no en slot derecho'
            unless $last_slot == $vis - 1;
    }
    if ($off == $w->{hist_o}) {
        push @issues, 'historico: barra 0 no cerca del borde izquierdo'
            unless $first_slot <= 1;
        push @issues, 'historico: deberia mostrar mas de 2 velas con visible<total'
            if $vis < $tot && $w->{data_count} < 10;
    }
    if ($off == $w->{min_o}) {
        push @issues, 'futuro: deben quedar exactamente keep velas de datos'
            unless $w->{data_count} == 2;
        push @issues, 'futuro: ultimas velas deben estar en slots bajos sin x_shift'
            unless $last_slot == 1;
    }

    if (@issues) {
        $fail++;
        print "FAIL [$label]\n";
        print "  $_\n" for @issues;
        print "  off=$w->{offset} vstart=$w->{view_start} data=$w->{data_start}..$w->{data_end} count=$w->{data_count} slots=$first_slot..$last_slot\n";
    }
    else {
        print "OK   [$label] off=$w->{offset} count=$w->{data_count} slots=$first_slot..$last_slot range=[$w->{min_o},$w->{max_o}]\n";
    }
}

my $off = 0;
$off -= -3;
print($off == 3 ? "OK   [pan izquierda => historico]\n" : "FAIL [pan direction]\n");
$fail++ unless $off == 3;

exit $fail ? 1 : 0;
