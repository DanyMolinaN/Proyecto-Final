package Market::Indicators::PivotAnchorsDavid;

# Portado desde Proyecto_David/Market/Indicators/PivotAnchors.pm.
# Mismo criterio de pivote que AnchoredVWAPDavid/AnchoredVolumeProfileDavid
# (ta.pivothigh/low(length,length)); solo registra el historial, no ancla nada.
# Se agrega recompute($md) para el contrato de Kevin (IndicatorManager).

use strict;
use warnings;

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        pivot_length => $args{pivot_length} // 50,
        _c      => [],
        _pivots => [],
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{_c}      = [];
    $self->{_pivots} = [];
}

sub get_values { return []; }

sub recompute {
    my ( $self, $md ) = @_;
    return unless $md;
    $self->reset();
    my $size = $md->size // 0;
    for my $idx ( 0 .. $size - 1 ) {
        $self->update_at_index( $md, $idx );
    }
}

sub update_at_index {
    my ( $self, $md, $idx ) = @_;
    my $c = $md->get_candle($idx);
    return unless defined $c;
    $self->{_c}[$idx] = $c;
    $self->_check_pivot($idx);
}

sub update_last {
    my ( $self, $md ) = @_;
    my $idx = $#{ $self->{_c} } + 1;
    my $c   = $md->last_candle;
    return unless defined $c;
    $self->{_c}[$idx] = $c;
    $self->_check_pivot($idx);
}

sub processed_last { return $#{ $_[0]->{_c} }; }
sub get_pivots     { return $_[0]->{_pivots}; }

sub _check_pivot {
    my ( $self, $idx ) = @_;
    my $L = $self->{pivot_length};
    return if $idx < 2 * $L;

    my $cand = $idx - $L;
    my $c    = $self->{_c};

    my ( $max_h, $min_l );
    for my $i ( ( $idx - 2 * $L ) .. $idx ) {
        my $cc = $c->[$i];
        next unless defined $cc;
        $max_h = $cc->{high} if !defined($max_h) || $cc->{high} > $max_h;
        $min_l = $cc->{low}  if !defined($min_l) || $cc->{low}  < $min_l;
    }
    return unless defined $max_h && defined $min_l;

    my $cand_c = $c->[$cand];
    return unless defined $cand_c;

    if ( $cand_c->{high} == $max_h ) {
        push @{ $self->{_pivots} }, { index => $cand, price => $max_h, type => 'high' };
    }
    if ( $cand_c->{low} == $min_l ) {
        push @{ $self->{_pivots} }, { index => $cand, price => $min_l, type => 'low' };
    }
}

1;
