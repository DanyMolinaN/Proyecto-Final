package Market::Concepts::SMCStructureEngine;

# =============================================================================
# SMCStructureEngine::Utils
# =============================================================================
# ATR, etiquetas HH/HL/LH/LL y helpers de bias.
# Continuacion del paquete Market::Concepts::SMCStructureEngine (split por SRP; sin cambio de API).
# =============================================================================

use strict;
use warnings;

sub _push_event {
    my ($self, $i, $evt) = @_;
    $self->{by_index}{$i} //= [];
    push @{ $self->{by_index}{$i} }, $evt;
}

sub _compute_atr {
    my ($candles, $last_idx, $period) = @_;
    return 1.0 if $last_idx < 1;
    my $start = $last_idx - $period + 1;
    $start = 1 if $start < 1;
    my ($sum, $count) = (0, 0);
    for my $i ($start .. $last_idx) {
        my $c  = $candles->[$i]     or next;
        my $cp = $candles->[$i - 1] or next;
        my $hl = $c->{high} - $c->{low};
        my $hc = abs($c->{high} - $cp->{close});
        my $lc = abs($c->{low}  - $cp->{close});
        my $tr = $hl;
        $tr = $hc if $hc > $tr;
        $tr = $lc if $lc > $tr;
        $sum += $tr;
        $count++;
    }
    return $count > 0 ? $sum / $count : 1.0;
}

sub _high_label {
    my ($prev, $curr) = @_;
    return '' unless defined $curr;
    return 'HH'  if !defined $prev || $curr > $prev;
    return 'LH'  if $curr < $prev;
    return 'EQH';
}
sub _low_label {
    my ($prev, $curr) = @_;
    return '' unless defined $curr;
    return 'LL'  if !defined $prev || $curr < $prev;
    return 'HL'  if $curr > $prev;
    return 'EQL';
}

sub _bias_str {
    my ($b) = @_;
    return 'bullish' if defined $b && $b == _BULLISH;
    return 'bearish' if defined $b && $b == _BEARISH;
    return 'neutral';
}

1;

__END__

=pod

=head1 NAME

Market::Concepts::SMCStructureEngine — v2.1 con No-Mitigation y EQL/EQH Single-Pass

=head1 DESCRIPTION

v2.1 agrega dos comportamientos clave sobre v2.0:

=over 4

=item B<Req-2 — No-Mitigación>: HH/HL/LH/LL/BOS/CHoCH/EQH/EQL son permanentes.
C<crossed=1> solo bloquea el re-disparo del mismo nivel, pero el overlay debe
dibujarlos siempre como registro histórico.

=item B<Req-3 — EQL/EQH Single-Pass O(N)>: Al detectar un EQL/EQH se inserta
la referencia en el HashMap C<%open_eq>. Cuando un BOS/CHoCH posterior cruza
el nivel, el cierre se realiza en O(1). Los eventos llevan C<start_index>,
C<end_index> (undef si aún abierto) e C<is_open>.

=back

=cut

1;
