package Market::Volume::PriceDistribution;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        bins      => {},
        total_vol => 0,
        bin_size  => $args{bin_size},
        min_price => undef,
        max_price => undef,
        %args,
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{bins}      = {};
    $self->{total_vol} = 0;
    $self->{min_price} = undef;
    $self->{max_price} = undef;
    return $self;
}

sub bin_size {
    my ($self) = @_;
    return $self->{bin_size} if defined $self->{bin_size};
    return 0.01;
}

sub _price_key {
    my ($self, $price) = @_;
    return sprintf('%.8f', $price);
}

sub _normalize_price {
    my ($self, $price) = @_;
    return undef unless defined $price;
    my $size = $self->bin_size();
    return int($price / $size + 0.5) * $size;
}

sub add_candle {
    my ($self, $candle) = @_;
    return unless $candle && ref $candle eq 'HASH';
    return unless defined $candle->{low} && defined $candle->{high} && defined $candle->{volume};

    my $low    = $candle->{low};
    my $high   = $candle->{high};
    my $volume = $candle->{volume} || 0;
    return if $volume <= 0;

    $self->{min_price} = $low  if !defined $self->{min_price} || $low  < $self->{min_price};
    $self->{max_price} = $high if !defined $self->{max_price} || $high > $self->{max_price};
    $self->{total_vol} += $volume;

    if ($high <= $low) {
        my $price = $self->_normalize_price($low);
        $self->_add_bin_volume($price, $volume);
        return;
    }

    my $size = $self->bin_size();
    my $start = $self->_normalize_price($low);
    my $end   = $self->_normalize_price($high);
    my $bins  = int(abs($end - $start) / $size) + 1;
    $bins = 1 if $bins < 1;
    my $per_bin = $volume / $bins;

    for (my $price = $start; $price <= $end + 1e-12; $price += $size) {
        $self->_add_bin_volume($price, $per_bin);
    }
}

sub _add_bin_volume {
    my ($self, $price, $volume) = @_;
    return unless defined $price;
    my $key = $self->_price_key($price);
    $self->{bins}{$key} ||= { price => $price, volume => 0 };
    $self->{bins}{$key}{volume} += $volume;
}

sub bins {
    my ($self) = @_;
    return $self->{bins};
}

sub sorted_bins {
    my ($self) = @_;
    my @bins = sort { $a->{price} <=> $b->{price} } values %{ $self->{bins} || {} };
    return \@bins;
}

sub total_volume {
    my ($self) = @_;
    return $self->{total_vol} || 0;
}

sub price_range {
    my ($self) = @_;
    return ($self->{min_price}, $self->{max_price});
}

1;
