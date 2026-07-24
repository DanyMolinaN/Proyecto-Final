package Market::Concepts::DSVWAP::ModularEngine;

use strict;
use warnings;

use Market::Concepts::DSVWAP::EventBus;
use Market::Concepts::DSVWAP::StateCache;
use Market::Concepts::DSVWAP::SwingEngine;
use Market::Concepts::DSVWAP::AnchorResolver;
use Market::Concepts::DSVWAP::VWAPEngine;
use Market::Concepts::DSVWAP::GhostEngine;
use Market::Concepts::DSVWAP::Event;

# =============================================================================
# Market::Concepts::DSVWAP::ModularEngine
# -----------------------------------------------------------------------------
# Orquestador arquitectónico. Conecta los motores modulares existentes mediante
# EventBus y devuelve el DTO que antes consumía DSVWAPOverlay.
#
# Responsabilidad EXCLUSIVA:
#   - Instanciar EventBus, StateCache y los cuatro motores.
#   - Iterar la serie cronológicamente.
#   - Despachar NewBarEvent por cada barra (is_last=1 únicamente en la última).
#   - Devolver el StateCache final como hashref compatible con EngineRegistry.
#
# Prohibido aquí:
#   - Matemáticas de VWAP, detección de pivots, cálculo de ghost.
#   - Escritura directa en StateCache.
#   - Llamadas directas a los motores (salvo process_bar, requerido por diseño).
#   - Acceso a getters o métodos privados de los motores.
# =============================================================================

# ---------------------------------------------------------------------------
# new(%args)
# Acepta los mismos argumentos que Engine->new() para compatibilidad total
# con EngineRegistry (que puede instanciar engines con configuración).
# ---------------------------------------------------------------------------
sub new {
    my ($class, %args) = @_;
    my $self = {
        length       => $args{length}       || 50,
        price_source => $args{price_source} || 'HLC3',
        show_miss    => defined $args{show_miss} ? $args{show_miss} : 1,

        # El cache interno se rellena en cada llamada a calculate().
        # Existe para que EngineRegistry pueda llamar a reset() sin
        # perder la referencia al objeto entre rebuilds.
        _last_result => {},
    };
    bless $self, $class;
    return $self;
}

# ---------------------------------------------------------------------------
# reset()
# Llamado por EngineRegistry antes de cada rebuild(). Limpia el resultado
# previo. Los motores modulares se recrean en cada calculate(), por lo que
# no hace falta resetearlos aquí individualmente.
# ---------------------------------------------------------------------------
sub reset {
    my ($self) = @_;
    $self->{_last_result} = {};
}

# ---------------------------------------------------------------------------
# calculate($market_data, %args) -> \%dto
#
# Interfaz pública idéntica a Engine->calculate().
# EngineRegistry llama: $engine->calculate($market_data, %args)
# Devuelve el mismo hashref DTO que DSVWAPOverlay espera.
# ---------------------------------------------------------------------------
sub calculate {
    my ($self, $market_data, %args) = @_;

    # Guardia: sin datos, devolver resultado vacío (misma semántica que Engine.pm)
    return $self->{_last_result}
        unless $market_data && $market_data->can('size') && $market_data->size() > 0;

    my $n = $market_data->size();

    # ------------------------------------------------------------------
    # 1. Crear infraestructura de comunicación y estado
    # ------------------------------------------------------------------
    my $bus   = Market::Concepts::DSVWAP::EventBus->new();
    my $cache = Market::Concepts::DSVWAP::StateCache->new();

    # ------------------------------------------------------------------
    # 2. Instanciar los cuatro motores exactamente una vez,
    #    inyectando EventBus, StateCache y configuración.
    #    El orden de instanciación determina el orden de suscripción,
    #    que debe respetar la cadena causal:
    #      SwingEngine emite SwingConfirmedEvent
    #      AnchorResolver escucha SwingConfirmedEvent, emite AnchorChangedEvent
    #      VWAPEngine     escucha AnchorChangedEvent
    #      GhostEngine    escucha NewBarEvent + AnchorChangedEvent
    # ------------------------------------------------------------------
    my $swing_engine = Market::Concepts::DSVWAP::SwingEngine->new(
        $bus,
        $self->{length},
    );

    my $anchor_resolver = Market::Concepts::DSVWAP::AnchorResolver->new(
        $bus,
        $self->{length},
        $self->{show_miss},
        $cache,
    );

    my $vwap_engine = Market::Concepts::DSVWAP::VWAPEngine->new(
        $bus,
        $cache,
        $self->{price_source},
    );

    my $ghost_engine = Market::Concepts::DSVWAP::GhostEngine->new(
        $bus,
        $cache,
        $self->{price_source},
        $self->{show_miss},
    );

    # ------------------------------------------------------------------
    # 3. Iterar la serie cronológicamente y despachar NewBarEvent.
    #    Equivalente al: for (my $b=0; $b<$n; $b++) del motor original.
    #
    #    Tras el dispatch de NewBarEvent, los motores suscritos
    #    (AnchorResolver, GhostEngine) se ejecutan sincrónicamente.
    #    SwingEngine y VWAPEngine exponen process_bar() porque requieren
    #    acceso directo a MarketData por índice, no están suscritos a
    #    NewBarEvent en sus implementaciones actuales.
    # ------------------------------------------------------------------
    for (my $b = 0; $b < $n; $b++) {
        my $is_last = ($b == $n - 1) ? 1 : 0;

        # Publicar NewBarEvent: AnchorResolver y GhostEngine reaccionan aquí.
        $bus->dispatch(
            Market::Concepts::DSVWAP::Event->new_bar($b, $market_data, $is_last)
        );

        # SwingEngine detecta pivots y emite SwingConfirmedEvent.
        # AnchorResolver reacciona emitiendo AnchorChangedEvent.
        # VWAPEngine reacciona a AnchorChangedEvent (suscripción interna).
        $swing_engine->process_bar($market_data, $b);

        # VWAPEngine acumula la barra actual (flujo normal O(1) o catch-up
        # si hubo cambio de ancla en esta misma iteración).
        $vwap_engine->process_bar($market_data, $b);
    }

    # ------------------------------------------------------------------
    # 4. Extraer el DTO del StateCache y devolverlo como hashref plano.
    #    Los campos coinciden exactamente con los que Engine.pm escribe
    #    en su $c hashref (compatibilidad total con DSVWAPOverlay).
    # ------------------------------------------------------------------
    my $result = {
        main_vwap      => $cache->{main_vwap},
        main_bands_u1  => $cache->{main_bands_u1},
        main_bands_l1  => $cache->{main_bands_l1},
        main_bands_u2  => $cache->{main_bands_u2},
        main_bands_l2  => $cache->{main_bands_l2},
        main_bands_u3  => $cache->{main_bands_u3},
        main_bands_l3  => $cache->{main_bands_l3},

        ghost_vwap     => $cache->{ghost_vwap},
        ghost_bands_u1 => $cache->{ghost_bands_u1},
        ghost_bands_l1 => $cache->{ghost_bands_l1},
        ghost_bands_u2 => $cache->{ghost_bands_u2},
        ghost_bands_l2 => $cache->{ghost_bands_l2},
        ghost_bands_u3 => $cache->{ghost_bands_u3},
        ghost_bands_l3 => $cache->{ghost_bands_l3},

        zigzag_lines   => $cache->{zigzag_lines},
        ghost_line     => $cache->{ghost_line},
        ghost_label    => $cache->{ghost_label},
    };

    $self->{_last_result} = $result;
    return $result;
}

1;
