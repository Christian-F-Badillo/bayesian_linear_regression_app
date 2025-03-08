library(ggplot2)
library(GGally)
library(viridis)
library(gridExtra)
library(invgamma)

mean_betas = matrix(c(0, 0), nrow=2, ncol=1)
cov_betas = matrix(c(1, 0, 0, 1), nrow=2, ncol=2)
dg_prior = 1
scale_prior = 3
n_samples = 5000

wine <- fread("http://archive.ics.uci.edu/ml/machine-learning-databases/wine-quality/winequality-white.csv", 
              sep=";", select = c(4, 8))

X <- wine$`residual sugar`
y <- wine$density

samples <- sampling_posterior(
    y = y, X = X,
    n_samples = n_samples
    )

apply (samples$beta, 2, mean)

p <- plot_joint_posterior(samples)

p


p2 <- plot_sigma_posterior(samples$sigma2)

p2

theor_post <- plot_marginal_theoretical(samples, X = X, y = y,
                                        mean_betas, cov_betas, dg_prior, 
                                        scale_prior)

theor_post

x <- cbind(1, X)
p3 <- plot_bayes_regression(y, x, samples, 
                            mean_betas, cov_betas, dg_prior, scale_prior,
                            use_theoretical = T, n_points = 4898)
p3

############################################################################
plot_bayes_regression <- function(y, X, posterior_samples, 
                                  beta_bar, A, nu0, s0_sq,  # Se agregan hiperparámetros
                                  alpha = 0.95, 
                                  use_theoretical = FALSE,
                                  n_points = 100) {
    
    library(ggplot2)
    library(HDInterval)
    
    # Validar que solo hay un predictor más intercepto
    if(ncol(posterior_samples$beta) != 2) {
        stop("La función solo funciona para modelos con intercepto y un predictor")
    }
    
    # Crear data frame para ggplot
    data_df <- data.frame(y = y, x = X[,2])  # Asume que X ya incluye intercepto
    
    # Secuencia de x para predicción
    x_seq <- seq(min(data_df$x), max(data_df$x), length.out = n_points)
    
    # Matriz de diseño para predicción
    X_pred <- cbind(1, x_seq)
    
    # Calcular estimación teórica exacta (usando prior conjugado)
    if(use_theoretical) {
        XtX <- crossprod(X)
        XtX_A <- XtX + A
        XtX_A_inv <- solve(XtX_A)
        
        beta_hat <- XtX_A_inv %*% (XtX %*% beta_bar + crossprod(X, y))
        
        S <- nu0 * s0_sq + crossprod(y) - t(beta_bar) %*% XtX %*% beta_bar
        sigma2_hat <- S / (nrow(X) + nu0)  # Media de la distribución inversa-gamma
        
        theoretical_fit <- X_pred %*% beta_hat
    }
    
    # Media posterior de beta
    beta_post_mean <- colMeans(posterior_samples$beta)
    
    # Generar distribuciones predictivas
    post_pred <- X_pred %*% t(posterior_samples$beta)
    
    # Calcular HDI
    hdi_bounds <- apply(post_pred, 1, function(x) hdi(x, credMass = alpha))
    
    # Crear data frame para gráfico
    plot_df <- data.frame(
        x = x_seq,
        post_mean = rowMeans(post_pred),
        hdi_lower = hdi_bounds[1,],
        hdi_upper = hdi_bounds[2,]
    )
    
    if(use_theoretical) plot_df$theoretical <- theoretical_fit
    
    # Crear gráfico base
    gg <- ggplot(data_df, aes(x = x, y = y)) +
        geom_point(alpha = 0.5, color = "#4B0082") +
        geom_line(data = plot_df, aes(y = post_mean, color = "Muestreo"),
                  linewidth = 1.2) +
        geom_ribbon(data = plot_df, aes(ymin = hdi_lower, ymax = hdi_upper),
                    fill = "#2F4F4F", alpha = 0.2) +
        labs(title = "",
             x = "Azúcar Residual",
             y = "Densidad",
             color = "Estimación") +  # Añadir título de la leyenda
        theme_minimal(base_size = 14) +
        theme(legend.position = "top")
    
    # Añadir línea teórica si se solicita
    if(use_theoretical) {
        gg <- gg + geom_line(data = plot_df, aes(y = theoretical, color = "Teórica"),
                             linewidth = 1.2, linetype = "dashed")
    }
    
    return(gg)
}


sampling_posterior <- function(y, X, 
                                           beta_bar = NULL, 
                                           A = NULL, 
                                           nu0 = 1, 
                                           s0_sq = 1, 
                                           intercept = TRUE, 
                                           n_samples = 10000) {
    
    # Cargar biblioteca necesaria
    if (!requireNamespace("MASS", quietly = TRUE)) {
        stop("El paquete 'MASS' es requerido. Instálalo con install.packages('MASS').")
    }
    
    # Agregar intercepto a X si es necesario
    if (intercept) {
        X <- cbind(1, X)
        colnames(X)[1] <- "(Intercept)"
    }
    
    k <- ncol(X)  # Número de predictores (incluyendo intercepto)
    n <- length(y)
    
    # Establecer valores por defecto para hiperparámetros si no se proporcionan
    if (is.null(beta_bar)) beta_bar <- rep(0, k)
    if (is.null(A)) A <- diag(1, k)
    
    # Validar dimensiones de hiperparámetros
    if (length(beta_bar) != k) {
        stop(paste("beta_bar debe tener longitud", k, "(coincidir con columnas de X)."))
    }
    if (!all(dim(A) == c(k, k))) {
        stop(paste("A debe ser una matriz", k, "x", k, "."))
    }
    
    # Precalcular términos necesarios
    XtX <- crossprod(X)
    XtX_A <- XtX + A
    XtX_A_inv <- solve(XtX_A)
    
    beta_post_mean <- XtX_A_inv %*% (crossprod(X, y) + A %*% beta_bar)
    
    # Calcular término escalar S
    S <- nu0 * s0_sq + 
        crossprod(y) + 
        t(beta_bar) %*% A %*% beta_bar - 
        t(beta_post_mean) %*% XtX_A %*% beta_post_mean
    
    # Parámetros para la inversa-gamma
    shape <- (n + nu0) / 2
    scale <- S / 2
    
    # Almacenamiento de muestras
    samples <- list(
        beta = matrix(NA, nrow = n_samples, ncol = k),
        sigma2 = numeric(n_samples)
    )
    colnames(samples$beta) <- colnames(X)
    
    # Muestreo Gibbs
    for (i in 1:n_samples) {
        # Muestrear sigma²
        samples$sigma2[i] <- 1 / rgamma(1, shape = shape, rate = scale)
        
        # Muestrear beta
        samples$beta[i, ] <- MASS::mvrnorm(
            n = 1,
            mu = XtX_A_inv %*% (crossprod(X, y) + A %*% beta_bar),
            Sigma = samples$sigma2[i] * XtX_A_inv
        )
    }
    
    return(samples)
}

# Si no tienes instaladas las librerías:
# install.packages(c("ggplot2", "GGally", "viridis"))

plot_joint_posterior <- function(posterior_samples, alpha = 0.7, bins = 30) {
    beta_df <- as.data.frame(posterior_samples$beta)
    
    # Función personalizada para gráficos inferiores (2D density)
    lower_fn <- function(data, mapping, ...) {
        ggplot(data = data, mapping = mapping) +
            geom_density_2d_filled(aes(fill = after_stat(level)), alpha = alpha, bins = bins) +
            scale_fill_viridis_d(option = "magma") +
            theme_minimal()
    }
    
    # Función personalizada para la diagonal (densidad)
    diag_fn <- function(data, mapping, ...) {
        ggplot(data = data, mapping = mapping) +
            geom_density(fill = "#4B0082", alpha = 0.6, color = "black") +
            theme_minimal()
    }
    
    # Función personalizada para gráficos superiores (correlación)
    upper_fn <- function(data, mapping, ...) {
        ggally_cor(data = data, mapping = mapping, 
                   size = 5, color = "darkred", 
                   display_grid = FALSE) +
            theme_void()
    }
    
    # Crear la matriz de gráficos
    gg <- ggpairs(
        data = beta_df,
        lower = list(continuous = wrap(lower_fn)),
        diag = list(continuous = wrap(diag_fn)),
        upper = list(continuous = wrap(upper_fn)),
        progress = FALSE
    ) +
        theme(
            panel.grid = element_blank(),
            strip.background = element_rect(fill = "#2F4F4F"),
            strip.text = element_text(color = "white", face = "bold")
        )
    
    return(gg)
}

plot_sigma_posterior <- function(sigma_samples, 
                                 fill_color = "#4B0082", 
                                 line_color = "#2F4F4F",
                                 cred_level = 0.95,
                                 bins = 30,
                                 alpha = 0.7) {
    
    # Calcular intervalos de credibilidad
    cred_interval <- quantile(sigma_samples, 
                              probs = c((1 - cred_level)/2, 1 - (1 - cred_level)/2))
    
    # Crear el gráfico
    gg <- ggplot(data.frame(sigma2 = sigma_samples), aes(x = sigma2)) +
        geom_histogram(aes(y = after_stat(density)),
                       fill = fill_color,
                       color = line_color,
                       alpha = alpha,
                       bins = bins) +
        geom_density(color = line_color, 
                     linewidth = 1.2, 
                     adjust = 1.5) +
        geom_vline(xintercept = cred_interval,
                   color = "firebrick",
                   linetype = "dashed",
                   linewidth = 0.8) +
        annotate("text",
                 x = mean(cred_interval),
                 y = Inf,
                 label = paste0(cred_level*100, "% CI: [", 
                                round(cred_interval[1], 2), ", ",
                                round(cred_interval[2], 2), "]"),
                 vjust = 1.5,
                 hjust = 0.5,
                 color = "firebrick",
                 size = 4) +
        labs(title = "Distribución Posterior de σ²",
             x = expression(paste("Valor de ", sigma^2)),
             y = "Densidad") +
        theme_minimal(base_size = 14) +
        theme(
            plot.title = element_text(face = "bold", hjust = 0.5),
            axis.title = element_text(color = "#2F4F4F"),
            panel.grid.minor = element_blank(),
            panel.grid.major = element_line(linewidth = 0.1),
            plot.background = element_rect(fill = "white", color = NA)
        )
    
    return(gg)
}


####################################################################3

plot_marginal_theoretical <- function(posterior_samples, 
                                      X, y, 
                                      beta_bar, 
                                      A, 
                                      nu0, 
                                      s0_sq) {
    
    if (ncol(posterior_samples$beta) != 2) {
        stop("La función solo funciona para modelos con intercepto y un predictor.")
    }
    
    # Agregar intercepto
    X <- cbind(1, X)  
    n <- nrow(X)
    k <- ncol(X)
    XtX <- crossprod(X)
    XtX_A <- XtX + A
    XtX_A_inv <- solve(XtX_A)
    
    # Media condicional corregida
    beta_post_mean <- XtX_A_inv %*% (crossprod(X, y) + A %*% beta_bar)
    
    # Cálculo correcto del parámetro S
    S <- nu0 * s0_sq + 
        crossprod(y) + 
        t(beta_bar) %*% A %*% beta_bar - 
        t(beta_post_mean) %*% XtX_A %*% beta_post_mean
    
    # Grados de libertad
    nu <- n + nu0  
    
    # Rangos para graficar distribuciones
    x_range_beta0 <- seq(
        min(posterior_samples$beta[, 1]) - 2*sd(posterior_samples$beta[, 1]),
        max(posterior_samples$beta[, 1]) + 2*sd(posterior_samples$beta[, 1]),
        length.out = 200
    )
    
    x_range_beta1 <- seq(
        min(posterior_samples$beta[, 2]) - 2*sd(posterior_samples$beta[, 2]),
        max(posterior_samples$beta[, 2]) + 2*sd(posterior_samples$beta[, 2]),
        length.out = 200
    )
    
    x_range_sigma <- seq(
        0.1,
        max(posterior_samples$sigma2) + 2*sd(posterior_samples$sigma2),
        length.out = 200
    )
    
    # Densidades teóricas corregidas
    theoretical_densities <- list(
        beta0 = data.frame(
            x = x_range_beta0,
            y = dt(
                (x_range_beta0 - beta_post_mean[1]) / sqrt((S / nu) * XtX_A_inv[1,1]),  
                df = nu
            ) / sqrt((S / nu) * XtX_A_inv[1,1])
        ), 
        
        beta1 = data.frame(
            x = x_range_beta1,
            y = dt(
                (x_range_beta1 - beta_post_mean[2]) / sqrt((S / nu) * XtX_A_inv[2,2]), 
                df = nu
            ) / sqrt((S / nu) * XtX_A_inv[2,2])
        )
    )
    
    # Obtener la altura máxima del histograma de sigma2
    hist_data <- hist(posterior_samples$sigma2, plot = FALSE, breaks = 50) 
    max_hist_density <- max(hist_data$density)  # Máxima densidad observada en el histograma
    
    # Calcular la densidad teórica sin escalar
    raw_density <- dinvgamma(x_range_sigma, shape = nu/2, rate = S/2)
    
    # Escalar la densidad teórica para que tenga una altura comparable con el histograma
    scaling_factor <- max_hist_density / max(raw_density)
    
    # Aplicar el escalamiento
    theoretical_densities$sigma2 <- data.frame(
        x = x_range_sigma,
        y = raw_density * scaling_factor / 120
    )
    
    # Gráficos
    plot_beta0 <- ggplot(data.frame(beta0 = posterior_samples$beta[,1]), aes(x = beta0)) +
        geom_histogram(aes(y = ..density..), bins = 50, fill = "#4B0082", alpha = 0.6) +
        geom_line(data = theoretical_densities$beta0, aes(x = x, y = y), 
                  color = "#FF6B6B", linewidth = 1.2) +
        labs(title = "Marginal de β₀", x = "β₀", y = "Densidad")
    
    plot_beta1 <- ggplot(data.frame(beta1 = posterior_samples$beta[,2]), aes(x = beta1)) +
        geom_histogram(aes(y = ..density..), bins = 50, fill = "#4B0082", alpha = 0.6) +
        geom_line(data = theoretical_densities$beta1, aes(x = x, y = y), 
                  color = "#FF6B6B", linewidth = 1.2) +
        labs(title = "Marginal de β₁", x = "β₁", y = "Densidad")
    
    plot_sigma2 <- ggplot(data.frame(sigma2 = posterior_samples$sigma2), aes(x = sigma2)) +
        geom_histogram(aes(y = ..density..), bins = 50, fill = "#2F4F4F", alpha = 0.6) +
        geom_line(data = theoretical_densities$sigma2, aes(x = x, y = y), 
                  color = "#2E8B57", linewidth = 1.2) +
        labs(title = "Marginal de σ²", x = "σ²", y = "Densidad")
    
    # Combinar gráficos
    grid.arrange(
        plot_beta0, 
        plot_beta1, 
        plot_sigma2,
        ncol = 2,
        layout_matrix = rbind(c(1, 2), c(3, 3))
    )
}
