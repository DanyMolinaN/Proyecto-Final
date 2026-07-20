package Market::Volume::SessionProfile;

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use lib File::Spec->catdir(dirname(__FILE__), '..', '..');

use Market::Volume::PriceDistribution;
use Market::Volume::POCCalculator;
use Market::Volume::ValueAreaCalculator;
use Market::Volume::NodeDetector;

sub new {
    my ($class, %args) = @_;
    my $self = {
        distribution        => Market::Volume::PriceDistribution->new(bin_size => $args{bin_size}),
        poc_calculator      => Market::Volume::POCCalculator->new(),
        value_area_calculator => Market::Volume::ValueAreaCalculator->new(percentage => $args{percentage}),
        node_detector       => Market::Volume::NodeDetector->new(threshold_factor => $args{threshold_factor}),
        session_start       => undef,
        session_end         => undef,
        metadata            => {},
        %args,
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{distribution}->reset();
    $self->{session_start} = undef;
    $self->{session_end}   = undef;
    $self->{metadata}      = {};
    return $self;
}

sub calculate {
    my ($self, $market_data, %args) = @_;
    return {} unless $market_data;

    $self->reset();
    my $replay_controller = $args{replay_controller};
    my $total = $market_data->size();
    my $visible_limit = defined $replay_controller && $replay_controller->can('visible_limit')
        ? $replay_controller->visible_limit($total)
        : undef;

    my $start_index = defined $args{start_index} ? $args{start_index} : 0;
    my $end_index   = defined $args{end_index}   ? $args{end_index}   : $visible_limit // ($total - 1);
    $end_index = $visible_limit if defined $visible_limit && $end_index > $visible_limit;
    $end_index = $total - 1 if !defined $end_index || $end_index > $total - 1;
    $start_index = 0 if $start_index < 0;
    return {} if $end_index < $start_index;

    # --- Bin size adaptativo (RENDIMIENTO) ---
    # Un bin fijo de 0.01 sobre un instrumento de precio alto (~24000) obliga a
    # PriceDistribution::add_candle a cientos de sub-iteraciones por vela, cada
    # una con un sprintf('%.8f'). Eso domina el coste de Volume Profile (que se
    # recalcula en cada render sobre la ventana visible) y congela la navegacion.
    # Si no hay bin_size explicito, se deriva uno que apunte a ~150 buckets sobre
    # el rango de precios real de la ventana; nunca mas fino que el 0.01 original.
    my $bin_size = $self->{bin_size};
    unless (defined $bin_size && $bin_size > 0) {
        my ($mn, $mx);
        for my $idx ($start_index .. $end_index) {
            my $c = $market_data->get_candle($idx) or next;
            $mn = $c->{low}  if !defined $mn || $c->{low}  < $mn;
            $mx = $c->{high} if !defined $mx || $c->{high} > $mx;
        }
        $bin_size = ($mx - $mn) / 150 if defined $mn && defined $mx && $mx > $mn;
        $bin_size = 0.01 if !defined $bin_size || $bin_size < 0.01;
    }
    $self->{distribution}{bin_size} = $bin_size;

    my $first_candle = $market_data->get_candle($start_index);
    my $last_candle  = $market_data->get_candle($end_index);
    return {} unless $first_candle && $last_candle;

    $self->{session_start} = $first_candle->{timestamp};
    $self->{session_end}   = $last_candle->{timestamp};

    for my $idx ($start_index .. $end_index) {
        my $candle = $market_data->get_candle($idx);
        next unless $candle;
        $self->{distribution}->add_candle($candle);
    }

    my ($min_price, $max_price) = $self->{distribution}->price_range();
    my $distribution = {
        bins         => $self->{distribution}->bins(),
        sorted_bins  => $self->{distribution}->sorted_bins(),
        total_volume => $self->{distribution}->total_volume(),
        min_price    => $min_price,
        max_price    => $max_price,
    };

    my $poc = $self->{poc_calculator}->compute_poc($self->{distribution});
    my $value_area = $self->{value_area_calculator}->compute_value_area($self->{distribution}, poc_price => $poc->{price});
    my $nodes = $self->{node_detector}->detect_nodes($self->{distribution});

    $self->{metadata} = {
        timeframe     => $args{timeframe} || $market_data->active_tf(),
        visible_limit => $visible_limit,
        start_index   => $start_index,
        end_index     => $end_index,
        session_start => $self->{session_start},
        session_end   => $self->{session_end},
        total_volume  => $distribution->{total_volume},
        bin_size      => $self->{distribution}->bin_size(),
    };

    return {
        distribution => $distribution,
        poc          => $poc,
        value_area   => $value_area,
        nodes        => $nodes,
        metadata     => $self->{metadata},
    };
}

1;
