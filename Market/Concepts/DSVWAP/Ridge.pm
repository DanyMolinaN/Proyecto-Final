package Market::Concepts::DSVWAP::Ridge;

# =============================================================================
# Ridge.pm — Fase 4: Ridge Regression multi-output en Perl puro (v2 optimizado)
# =============================================================================
# OPTIMIZACION v2:
#   - Calcula XtX y Xty UNA sola vez; para cada lambda solo modifica diagonal
#   - Solver Gauss-Jordan in-place sobre [A|b] en lugar de calcular A^-1 completa
#   - Esto reduce el costo de O(p^3 * lambdas * targets) a O(N*p^2 + p^3*lambdas*targets)
#
# INVARIANTE CRITICO: I_mod[0][0] = 0 (intercepto SIN regularizar, verificado en ridge_fit)
#
# INTERFAZ PUBLICA:
#   compute_XtX_Xty(\@X, \@y)               -> (\@XtX, \@Xty)
#   solve_ridge(\@XtX, \@Xty, $lambda, $p)  -> \@beta   (solver directo sin invertir)
#   ridge_fit(\@X, \@y, $lambda)             -> \@beta   (api de alto nivel)
#   ridge_predict(\@X, \@beta)               -> \@preds
#   postprocess_predictions(...)             -> (...)
# =============================================================================

use strict;
use warnings;
use Carp qw(croak carp);

# ---------------------------------------------------------------------------
# compute_XtX(\@X)
#   X: [N x p] AoA
#   Retorna: \@XtX [p x p]
# ---------------------------------------------------------------------------
sub compute_XtX {
    my ($class, $X) = @_;
    my $N = scalar @$X;
    my $p = scalar @{$X->[0]};

    my @XtX;
    for my $i (0 .. $p - 1) {
        for my $j (0 .. $p - 1) {
            $XtX[$i][$j] = 0;
        }
    }

    for my $n (0 .. $N - 1) {
        my $row = $X->[$n];
        for my $i (0 .. $p - 1) {
            my $xi = $row->[$i];
            # XtX es simetrica: acumular solo triangulo superior + copiar
            for my $j ($i .. $p - 1) {
                my $v = $xi * $row->[$j];
                $XtX[$i][$j] += $v;
                $XtX[$j][$i] += $v if $j > $i;
            }
        }
    }

    return \@XtX;
}

# ---------------------------------------------------------------------------
# compute_Xty(\@X, \@y_plain)
#   Retorna: \@Xty [p x 1]
# ---------------------------------------------------------------------------
sub compute_Xty {
    my ($class, $X, $y) = @_;
    my $N = scalar @$X;
    my $p = scalar @{$X->[0]};

    my @Xty;
    for my $i (0 .. $p - 1) {
        $Xty[$i] = 0;
    }

    for my $n (0 .. $N - 1) {
        my $row = $X->[$n];
        my $yn  = $y->[$n];
        for my $i (0 .. $p - 1) {
            $Xty[$i] += $row->[$i] * $yn;
        }
    }

    return \@Xty;
}

# ---------------------------------------------------------------------------
# solve_ridge(\@XtX, \@Xty, $lambda, $p)
#   Resuelve (XtX + lambda*I_mod) beta = Xty usando Gauss-Jordan con pivoteo parcial.
#   NO calcula la inversa completa — resuelve el sistema directamente.
#   I_mod[0][0] = 0: el intercepto no se regulariza.
#
#   Recibe XtX y Xty como referencias (NO los modifica — copia interna).
# ---------------------------------------------------------------------------
sub solve_ridge {
    my ($class, $XtX_ref, $Xty_ref, $lambda, $p) = @_;
    $lambda //= 1.0;

    # Construir copia de A = XtX + lambda * I_mod  [p x p]
    # y el vector b = Xty  [p]
    # Forma aumentada [A | b]  [p x (p+1)]
    my @aug;
    for my $i (0 .. $p - 1) {
        for my $j (0 .. $p - 1) {
            $aug[$i][$j] = $XtX_ref->[$i][$j];
        }
        # Regularizacion: diagonal (excepto intercepto en pos 0)
        $aug[$i][$i] += $lambda if $i > 0;
        # Columna aumentada (lado derecho)
        $aug[$i][$p] = $Xty_ref->[$i];
    }

    # VERIFICACION: intercepto[0][0] NO fue aumentado con lambda
    # (la linea anterior tiene 'if $i > 0', por lo que $aug[0][0] = XtX[0][0] sin lambda)

    my $EPS = 1e-14;

    # Gauss-Jordan con pivoteo parcial sobre [A | b]
    for my $col (0 .. $p - 1) {
        # Pivot parcial
        my $max_val = abs($aug[$col][$col]);
        my $max_row = $col;
        for my $row ($col + 1 .. $p - 1) {
            if (abs($aug[$row][$col]) > $max_val) {
                $max_val = abs($aug[$row][$col]);
                $max_row = $row;
            }
        }
        @aug[$col, $max_row] = @aug[$max_row, $col] if $max_row != $col;

        my $pivot = $aug[$col][$col];
        if (abs($pivot) < $EPS) {
            carp "solve_ridge: pivot casi cero en col=$col (lambda=$lambda) — posible singularidad";
            return undef;
        }

        # Normalizar fila pivot (divide por pivot)
        my $inv_pivot = 1.0 / $pivot;
        for my $j ($col .. $p) {
            $aug[$col][$j] *= $inv_pivot;
        }

        # Eliminar en todas las otras filas (Gauss-Jordan completo)
        for my $row (0 .. $p - 1) {
            next if $row == $col;
            my $factor = $aug[$row][$col];
            next if abs($factor) < $EPS;
            for my $j ($col .. $p) {
                $aug[$row][$j] -= $factor * $aug[$col][$j];
            }
        }
    }

    # Extraer solucion (columna p)
    my @beta = map { $aug[$_][$p] } 0 .. $p - 1;
    return \@beta;
}

# ---------------------------------------------------------------------------
# ridge_fit(\@X, \@y, $lambda) -> \@beta
#   API de alto nivel: calcula XtX/Xty y resuelve.
#   Util cuando se llama una sola vez. Para grid search usar compute+solve por separado.
# ---------------------------------------------------------------------------
sub ridge_fit {
    my ($class, $X, $y, $lambda) = @_;
    $lambda //= 1.0;
    my $p = scalar @{$X->[0]};

    # Convertir y plano si hace falta
    my @y_plain = ref($y->[0]) ? map { $_->[0] } @$y : @$y;

    my $XtX = $class->compute_XtX($X);
    my $Xty = $class->compute_Xty($X, \@y_plain);
    my $beta = $class->solve_ridge($XtX, $Xty, $lambda, $p);
    croak "ridge_fit: solver fallo para lambda=$lambda" unless defined $beta;
    return $beta;
}

# ---------------------------------------------------------------------------
# ridge_predict(\@X, \@beta) -> \@preds
# ---------------------------------------------------------------------------
sub ridge_predict {
    my ($class, $X, $beta) = @_;
    my $p = scalar @$beta;
    my @preds;
    for my $row (@$X) {
        my $yhat = 0;
        $yhat += $row->[$_] * $beta->[$_] for 0 .. $p - 1;
        push @preds, $yhat;
    }
    return \@preds;
}

# ---------------------------------------------------------------------------
# postprocess_predictions(\@r3, \@r5, \@r10, \@r15)
#   -> (\@f3, \@f5, \@f10, \@f15, \@violated)
#
#   Paso 1: clip no-negativo  max(0, pred)
#   Paso 2: cummax  y3 <= y5 <= y10 <= y15
#   violated: 1 si la prediccion CRUDA (antes de clip/mono) ya violaba monotonia
# ---------------------------------------------------------------------------
sub postprocess_predictions {
    my ($class, $r3, $r5, $r10, $r15) = @_;
    my $N = scalar @$r3;
    my (@f3, @f5, @f10, @f15, @violated);

    for my $i (0 .. $N - 1) {
        # Detectar violacion en crudo (antes de cualquier correccion)
        my $viol = ($r3->[$i]  > $r5->[$i]
                 || $r5->[$i]  > $r10->[$i]
                 || $r10->[$i] > $r15->[$i]) ? 1 : 0;
        push @violated, $viol;

        # Paso 1: clip a no-negativo
        my ($c3, $c5, $c10, $c15) = map { $_ < 0 ? 0 : $_ }
            ($r3->[$i], $r5->[$i], $r10->[$i], $r15->[$i]);

        # Paso 2: cummax por horizonte
        my $y3  = $c3;
        my $y5  = $c5  < $y3  ? $y3  : $c5;
        my $y10 = $c10 < $y5  ? $y5  : $c10;
        my $y15 = $c15 < $y10 ? $y10 : $c15;

        push @f3,  $y3;
        push @f5,  $y5;
        push @f10, $y10;
        push @f15, $y15;
    }

    return (\@f3, \@f5, \@f10, \@f15, \@violated);
}

1;
