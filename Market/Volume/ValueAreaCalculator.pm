package Market::Volume::ValueAreaCalculator;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        %args,
    };
    $self->{percentage} //= 0.7;
    bless $self, $class;
    return $self;
}

sub compute_value_area {
    my ($self, $distribution, %args) = @_;
    return {} unless $distribution && ref $distribution->{bins} eq 'HASH';

    my $percentage = $args{percentage} // $self->{percentage};
    $percentage = 0.7 if $percentage <= 0 || $percentage > 1;

    my @bins = sort { $a->{price} <=> $b->{price} } values %{ $distribution->{bins} };
    return {} unless @bins;

    my $total_volume = 0;
    $total_volume += $_->{volume} for @bins;
    return {} unless $total_volume > 0;

    my $target_volume = $total_volume * $percentage;
    my $poc_price = $args{poc_price};

    unless (defined $poc_price) {
        my $best = $bins[0];
        for my $bin (@bins) {
            $best = $bin if $bin->{volume} > $best->{volume};
        }
        $poc_price = $best->{price};
    }

    my %by_price = map { $_->{price} => $_ } @bins;
    my @price_list = map { $_->{price} } @bins;
    my %index_of = map { $price_list[$_] => $_ } 0..$#price_list;
    my $poc_index = $index_of{$poc_price} // int(@bins / 2);

    my $low_index  = $poc_index;
    my $high_index = $poc_index;
    my $accum      = $by_price{$poc_price}{volume} // 0;

    while ($accum < $target_volume) {
        my $next_low  = $low_index  > 0 ? $low_index  - 1 : undef;
        my $next_high = $high_index < $#price_list ? $high_index + 1 : undef;
        my $low_volume  = defined $next_low  ? $by_price{$price_list[$next_low]}{volume}  : -1;
        my $high_volume = defined $next_high ? $by_price{$price_list[$next_high]}{volume} : -1;

        if (defined $next_low && defined $next_high) {
            if ($high_volume >= $low_volume) {
                $high_index++;
                $accum += $by_price{$price_list[$high_index]}{volume} // 0;
            }
            else {
                $low_index--;
                $accum += $by_price{$price_list[$low_index]}{volume} // 0;
            }
        }
        elsif (defined $next_high) {
            $high_index++;
            $accum += $by_price{$price_list[$high_index]}{volume} // 0;
        }
        elsif (defined $next_low) {
            $low_index--;
            $accum += $by_price{$price_list[$low_index]}{volume} // 0;
        }
        else {
            last;
        }
    }

    return {
        value_area_low  => $price_list[$low_index],
        value_area_high => $price_list[$high_index],
        poc_price       => $poc_price,
        total_volume    => $total_volume,
        target_volume   => $target_volume,
        included_volume => $accum,
    };
}

1;
