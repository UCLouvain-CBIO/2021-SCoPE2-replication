##' @title ComBat v3.34 batch correction
##'
##' @description
##'
##' Older version of ComBat (sva version 3.34.0). This is for
##' compatibility with the replication of SCoPE2.
##'
##' ComBat allows users to adjust for batch effects in datasets where
##' the batch covariate is known, using methodology described in
##' Johnson et al. 2007. It uses either parametric or non-parametric
##' empirical Bayes frameworks for adjusting data for batch effects.
##' Users are returned an expression matrix that has been corrected
##' for batch effects. The input data are assumed to be cleaned and
##' normalized before batch effect removal.
##'
##' @param dat Genomic measure matrix (dimensions probe x sample) -
##'     for example, expression matrix
##'
##' @param batch Batch covariate (only one batch allowed)
##'
##' @param mod Model matrix for outcome of interest and other
##'     covariates besides batch
##'
##' @param par.prior (Optional) TRUE indicates parametric adjustments
##'     will be used, FALSE indicates non-parametric adjustments will
##'     be used
##'
##' @param prior.plots (Optional) TRUE give prior plots with black as
##'      a kernel estimate of the empirical batch effect density and
##'      red as the parametric
##'
##' @param mean.only (Optional) FALSE If TRUE ComBat only corrects the
##'     mean of the batch effect (no scale adjustment)
##'
##' @param ref.batch (Optional) NULL If given, will use the selected
##'     batch as a reference for batch adjustment.
##'
##' @param BPPARAM (Optional) BiocParallelParam for parallel operation
##'
##' @export
##'
##' @import sva
##'
##' @import BiocParallel
##'
##' @import graphics
##'
##' @importFrom stats density dnorm qqnorm qqline qgamma ppoints qqplot model.matrix dist cor var
##'
##' @importFrom matrixStats rowVars colSds
##'
##' @return data A probe x sample genomic measure matrix, adjusted for batch effects.
##'
##' @examples
##' library(sva)
##' library(bladderbatch)
##' data(bladderdata)
##' dat <- bladderEset[1:50,]
##'
##' pheno <- pData(dat)
##' edata <- exprs(dat)
##' batch <- pheno$batch
##' mod <- model.matrix(~as.factor(cancer), data=pheno)
##'
##' # parametric adjustment
##' combat_edata1 <- ComBat(dat=edata, batch=batch, mod=NULL, par.prior=TRUE, prior.plots=FALSE)
##'
##' # non-parametric adjustment, mean-only version
##' combat_edata2 <- ComBat(dat=edata, batch=batch, mod=NULL, par.prior=FALSE, mean.only=TRUE)
##'
##' # reference-batch version, with covariates
##' combat_edata3 <- ComBat(dat=edata, batch=batch, mod=mod, par.prior=TRUE, ref.batch=3)
##'
ComBatv3.34 <- function (dat, batch, mod = NULL, par.prior = TRUE, prior.plots = FALSE,
                         mean.only = FALSE, ref.batch = NULL,
                         BPPARAM = BiocParallel::bpparam("SerialParam")) {
    
    ## code taken from sva - used exclusively to reproduce obtained
    ## with version 3.34
    stopifnot(requireNamespace("sva")) ## works for sva_3.37.0
    
    ## these internal function are not exported from the more recent
    ## versions of sva.
    sva_Beta.NA <- function (y, X) {
        des <- X[!is.na(y), ]
        y1 <- y[!is.na(y)]
        B <- solve(crossprod(des), crossprod(des, y1))
        B
    }
    
    sva_aprior  <- function (gamma.hat) {
        m <- mean(gamma.hat)
        s2 <- var(gamma.hat)
        (2 * s2 + m^2)/s2
    }
    
    sva_bprior <- function (gamma.hat) {
        m <- mean(gamma.hat)
        s2 <- var(gamma.hat)
        (m * s2 + m^3)/s2
    }
    
    sva_dinvgamma  <- function (x, shape, rate = 1/scale, scale = 1) {
        stopifnot(shape > 0)
        stopifnot(rate > 0)
        ifelse(x <= 0, 0, ((rate^shape)/gamma(shape)) * x^(-shape -
                                                               1) * exp(-rate/x))
    }
    
    sva_postmean <- function (g.hat, g.bar, n, d.star, t2) {
        (t2 * n * g.hat + d.star * g.bar)/(t2 * n + d.star)
    }
    
    sva_postvar <- function (sum2, n, a, b) {
        (0.5 * sum2 + b)/(n/2 + a - 1)
    }
    
    sva_it.sol  <- function (sdat, g.hat, d.hat, g.bar, t2, a, b, conv = 1e-04) {
        n <- rowSums(!is.na(sdat))
        g.old <- g.hat
        d.old <- d.hat
        change <- 1
        count <- 0
        while (change > conv) {
            g.new <- sva_postmean(g.hat, g.bar, n, d.old, t2)
            sum2 <- rowSums((sdat - g.new %*% t(rep(1, ncol(sdat))))^2,
                            na.rm = TRUE)
            d.new <- sva_postvar(sum2, n, a, b)
            change <- max(abs(g.new - g.old)/g.old, abs(d.new - d.old)/d.old)
            g.old <- g.new
            d.old <- d.new
            count <- count + 1
        }
        adjust <- rbind(g.new, d.new)
        rownames(adjust) <- c("g.star", "d.star")
        adjust
    }
    
    
    sva_int.eprior <- function (sdat, g.hat, d.hat) {
        g.star <- d.star <- NULL
        r <- nrow(sdat)
        for (i in 1:r) {
            g <- g.hat[-i]
            d <- d.hat[-i]
            x <- sdat[i, !is.na(sdat[i, ])]
            n <- length(x)
            j <- numeric(n) + 1
            dat <- matrix(as.numeric(x), length(g), n, byrow = TRUE)
            resid2 <- (dat - g)^2
            sum2 <- resid2 %*% j
            LH <- 1/(2 * pi * d)^(n/2) * exp(-sum2/(2 * d))
            LH[LH == "NaN"] = 0
            g.star <- c(g.star, sum(g * LH)/sum(LH))
            d.star <- c(d.star, sum(d * LH)/sum(LH))
        }
        adjust <- rbind(g.star, d.star)
        rownames(adjust) <- c("g.star", "d.star")
        adjust
    }
    
    if (mean.only) {
        message("Using the 'mean only' version of ComBat")
    }
    if (length(dim(batch)) > 1) {
        stop("This version of ComBat only allows one batch variable")
    }
    batch <- as.factor(batch)
    batchmod <- model.matrix(~-1 + batch)
    if (!is.null(ref.batch)) {
        if (!(ref.batch %in% levels(batch))) {
            stop("reference level ref.batch is not one of the levels of the batch variable")
        }
        cat("Using batch =", ref.batch, "as a reference batch (this batch won't change)\n")
        ref <- which(levels(as.factor(batch)) == ref.batch)
        batchmod[, ref] <- 1
    }
    else {
        ref <- NULL
    }
    message("Found", nlevels(batch), "batches")
    n.batch <- nlevels(batch)
    batches <- list()
    for (i in 1:n.batch) {
        batches[[i]] <- which(batch == levels(batch)[i])
    }
    n.batches <- sapply(batches, length)
    if (any(n.batches == 1)) {
        mean.only = TRUE
        message("Note: one batch has only one sample, setting mean.only=TRUE")
    }
    n.array <- sum(n.batches)
    design <- cbind(batchmod, mod)
    check <- apply(design, 2, function(x) all(x == 1))
    if (!is.null(ref)) {
        check[ref] <- FALSE
    }
    design <- as.matrix(design[, !check])
    message("Adjusting for", ncol(design) - ncol(batchmod),
            "covariate(s) or covariate level(s)")
    if (qr(design)$rank < ncol(design)) {
        if (ncol(design) == (n.batch + 1)) {
            stop("The covariate is confounded with batch! Remove the covariate and rerun ComBat")
        }
        if (ncol(design) > (n.batch + 1)) {
            if ((qr(design[, -c(1:n.batch)])$rank < ncol(design[,
                                                                -c(1:n.batch)]))) {
                stop("The covariates are confounded! Please remove one or more of the covariates so the design is not confounded")
            }
            else {
                stop("At least one covariate is confounded with batch! Please remove confounded covariates and rerun ComBat")
            }
        }
    }
    NAs <- any(is.na(dat))
    if (NAs) {
        message(c("Found", sum(is.na(dat)), "Missing Data Values"),
                sep = " ")
    }
    cat("Standardizing Data across genes\n")
    if (!NAs) {
        B.hat <- solve(crossprod(design), tcrossprod(t(design),
                                                     as.matrix(dat)))
    }
    else {
        B.hat <- apply(dat, 1, sva_Beta.NA, design)
    }
    if (!is.null(ref.batch)) {
        grand.mean <- t(B.hat[ref, ])
    }
    else {
        grand.mean <- crossprod(n.batches/n.array, B.hat[1:n.batch,
        ])
    }
    if (!NAs) {
        if (!is.null(ref.batch)) {
            ref.dat <- dat[, batches[[ref]]]
            var.pooled <- ((ref.dat - t(design[batches[[ref]],
            ] %*% B.hat))^2) %*% rep(1/n.batches[ref], n.batches[ref])
        }
        else {
            var.pooled <- ((dat - t(design %*% B.hat))^2) %*%
                rep(1/n.array, n.array)
        }
    }
    else {
        if (!is.null(ref.batch)) {
            ref.dat <- dat[, batches[[ref]]]
            var.pooled <- rowVars(ref.dat - t(design[batches[[ref]],
            ] %*% B.hat), na.rm = TRUE)
        }
        else {
            var.pooled <- rowVars(dat - t(design %*% B.hat),
                                  na.rm = TRUE)
        }
    }
    stand.mean <- t(grand.mean) %*% t(rep(1, n.array))
    if (!is.null(design)) {
        tmp <- design
        tmp[, c(1:n.batch)] <- 0
        stand.mean <- stand.mean + t(tmp %*% B.hat)
    }
    s.data <- (dat - stand.mean)/(sqrt(var.pooled) %*% t(rep(1,
                                                             n.array)))
    message("Fitting L/S model and finding priors")
    batch.design <- design[, 1:n.batch]
    if (!NAs) {
        gamma.hat <- solve(crossprod(batch.design), tcrossprod(t(batch.design),
                                                               as.matrix(s.data)))
    }
    else {
        gamma.hat <- apply(s.data, 1, sva_Beta.NA, batch.design)
    }
    delta.hat <- NULL
    for (i in batches) {
        if (mean.only == TRUE) {
            delta.hat <- rbind(delta.hat, rep(1, nrow(s.data)))
        }
        else {
            delta.hat <- rbind(delta.hat, rowVars(s.data[, i],
                                                  na.rm = TRUE))
        }
    }
    gamma.bar <- rowMeans(gamma.hat)
    t2 <- rowVars(gamma.hat)
    a.prior <- apply(delta.hat, 1, sva_aprior)
    b.prior <- apply(delta.hat, 1, sva_bprior)
    if (prior.plots && par.prior) {
        par(mfrow = c(2, 2))
        tmp <- density(gamma.hat[1, ])
        plot(tmp, type = "l", main = expression(paste("Density Plot of First Batch ",
                                                      hat(gamma))))
        xx <- seq(min(tmp$x), max(tmp$x), length = 100)
        lines(xx, dnorm(xx, gamma.bar[1], sqrt(t2[1])), col = 2)
        qqnorm(gamma.hat[1, ], main = expression(paste("Normal Q-Q Plot of First Batch ",
                                                       hat(gamma))))
        qqline(gamma.hat[1, ], col = 2)
        tmp <- density(delta.hat[1, ])
        xx <- seq(min(tmp$x), max(tmp$x), length = 100)
        tmp1 <- list(x = xx, y = sva_dinvgamma(xx, a.prior[1], b.prior[1]))
        plot(tmp, typ = "l", ylim = c(0, max(tmp$y, tmp1$y)),
             main = expression(paste("Density Plot of First Batch ",
                                     hat(delta))))
        lines(tmp1, col = 2)
        invgam <- 1/qgamma(1 - ppoints(ncol(delta.hat)), a.prior[1],
                           b.prior[1])
        qqplot(invgam, delta.hat[1, ], main = expression(paste("Inverse Gamma Q-Q Plot of First Batch ",
                                                               hat(delta))), ylab = "Sample Quantiles", xlab = "Theoretical Quantiles")
        lines(c(0, max(invgam)), c(0, max(invgam)), col = 2)
    }
    gamma.star <- delta.star <- matrix(NA, nrow = n.batch, ncol = nrow(s.data))
    if (par.prior) {
        message("Finding parametric adjustments")
        results <- BiocParallel::bplapply(1:n.batch, function(i) {
            if (mean.only) {
                gamma.star <- sva_postmean(gamma.hat[i, ], gamma.bar[i],
                                           1, 1, t2[i])
                delta.star <- rep(1, nrow(s.data))
            }
            else {
                temp <- sva_it.sol(s.data[, batches[[i]]], gamma.hat[i,
                ], delta.hat[i, ], gamma.bar[i], t2[i], a.prior[i],
                b.prior[i])
                gamma.star <- temp[1, ]
                delta.star <- temp[2, ]
            }
            list(gamma.star = gamma.star, delta.star = delta.star)
        }, BPPARAM = BPPARAM)
        for (i in 1:n.batch) {
            gamma.star[i, ] <- results[[i]]$gamma.star
            delta.star[i, ] <- results[[i]]$delta.star
        }
    }
    else {
        message("Finding nonparametric adjustments")
        results <- BiocParallel::bplapply(1:n.batch, function(i) {
            if (mean.only) {
                delta.hat[i, ] = 1
            }
            temp <- sva_int.eprior(as.matrix(s.data[, batches[[i]]]),
                                   gamma.hat[i, ], delta.hat[i, ])
            list(gamma.star = temp[1, ], delta.star = temp[2, ])
        }, BPPARAM = BPPARAM)
        for (i in 1:n.batch) {
            gamma.star[i, ] <- results[[i]]$gamma.star
            delta.star[i, ] <- results[[i]]$delta.star
        }
    }
    if (!is.null(ref.batch)) {
        gamma.star[ref, ] <- 0
        delta.star[ref, ] <- 1
    }
    message("Adjusting the Data\n")
    bayesdata <- s.data
    j <- 1
    for (i in batches) {
        bayesdata[, i] <- (bayesdata[, i] - t(batch.design[i,
        ] %*% gamma.star))/(sqrt(delta.star[j, ]) %*% t(rep(1,
                                                            n.batches[j])))
        j <- j + 1
    }
    bayesdata <- (bayesdata * (sqrt(var.pooled) %*% t(rep(1,
                                                          n.array)))) + stand.mean
    if (!is.null(ref.batch)) {
        bayesdata[, batches[[ref]]] <- dat[, batches[[ref]]]
    }
    return(bayesdata)
}

##' @title KNN imputation (for replication)
##'
##'
##' @description
##'
##' The function imputes missing data using the k-nearest neighbours
##' (KNN) approach using Euclidean distance as a similarity measure
##' between the cells. This function was provided as part of the
##' SCoPE2 publication (Specht et al. 2021).
##'
##' @param object A `QFeatures` object
##'
##' @param i  A `numeric()` or `character()` vector indicating from
##'     which assays the `rowData` should be taken.
##'
##' @param name A `character(1)` naming the new assay name. Default is
##' `KNNimputedAssay`.
##'
##' @param k An `integer(1)` giving the number of neighbours to use.
##'
##' @export
##'
##' @import QFeatures
##'
##' @importFrom SummarizedExperiment assay assay<- rowData rowData<-
##'
##' @return An object of class `QFeatures` containing an extra assay
##'     with imputed values.
##'
##' @references Specht, Harrison, Edward Emmott, Aleksandra A. Petelski,
##'     R. Gray Huffman, David H. Perlman, Marco Serra, Peter Kharchenko,
##'     Antonius Koller, and Nikolai Slavov. 2021. “Single-Cell Proteomic
##'     and Transcriptomic Analysis of Macrophage Heterogeneity Using
##'     SCoPE2.” Genome Biology 22 (1): 50.
##'
##' @source The implementation of the imputation was retrieved from
##'     https://github.com/SlavovLab/SCoPE2
##'
imputeKnnSCoPE2 <- function(object, i, name = "KNNimputedAssay", k = 3){
    
    oldi <- i
    exp <- object[[i]]
    dat <- assay(exp)
    
    # Create a copy of the data, NA values to be filled in later
    dat.imp<-dat
    
    # Calculate similarity metrics for all column pairs (default is Euclidean distance)
    dist.mat<-as.matrix( dist(t(dat)) )
    #dist.mat<-as.matrix(as.dist( dist.cosine(t(dat)) ))
    
    # Column names of the similarity matrix, same as data matrix
    cnames<-colnames(dist.mat)
    
    # For each column in the data...
    for(X in cnames){
        
        # Find the distances of all other columns to that column
        distances<-dist.mat[, X]
        
        # Reorder the distances, smallest to largest (this will reorder the column names as well)
        distances.ordered<-distances[order(distances, decreasing = F)]
        
        # Reorder the data matrix columns, smallest distance to largest from the column of interest
        # Obviously, first column will be the column of interest, column X
        dat.reordered<-dat[ , names(distances.ordered ) ]
        
        # Take the values in the column of interest
        vec<-dat[, X]
        
        # Which entries are missing and need to be imputed...
        na.index<-which( is.na(vec) )
        
        # For each of the missing entries (rows) in column X...
        for(i in na.index){
            
            # Find the most similar columns that have a non-NA value in this row
            closest.columns<-names( which( !is.na(dat.reordered[i, ])  ) )
            
            # If there are more than k such columns, take the first k most similar
            if( length(closest.columns)>k ){
                # Replace NA in column X with the mean the same row in k of the most similar columns
                vec[i]<-mean( dat[ i, closest.columns[1:k] ] )
            }
            
            # If there are less that or equal to k columns, take all the columns
            if( length(closest.columns)<=k ){
                # Replace NA in column X with the mean the same row in all of the most similar columns
                vec[i]<-mean( dat[ i, closest.columns ])
            }
        }
        # Populate a the matrix with the new, imputed values
        dat.imp[,X]<-vec
    }
    
    assay(exp) <- dat.imp
    object <- addAssay(object, exp, name = name)
    addAssayLinkOneToOne(object, from = oldi, to = name)
}


##' @title PCA plot suggested by SCoPE2
##'
##' @description
##'
##' The function performs a weighted principal component analysis (PCA)
##' as suggested by Specht et al. The PCA is performed on the
##' correlation matrix where the rows (features) are weighted according
##' to the sum of the correlation with the other rows.
##'
##' @param object A `SingleCellExperiment` object
##'
##' @param center A `logical(1)` indicating whether the columns of the
##'     weighted input matrix should be mean centered.
##'
##' @param scale A `logical(1)` indicating whether the columns of the
##'     weighted input matrix should be scaled to unit variance.
##'
##' @return An object of class `eigen` containing the computed
##'     eigenvector and eigenvalues.
##'
##' @export
##'
##' @import SingleCellExperiment
##'
##' @import scp
##'
##' @import scpdata
##'
##' @references
##'
##' Specht, Harrison, Edward Emmott, Aleksandra A. Petelski, R. Gray
##' Huffman, David H. Perlman, Marco Serra, Peter Kharchenko, Antonius
##' Koller, and Nikolai Slavov. 2021. "Single-Cell Proteomic and
##' Transcriptomic Analysis of Macrophage Heterogeneity Using SCoPE2.”
##' Genome Biology 22 (1): 50.
##' [link to article](http://dx.doi.org/10.1186/s13059-021-02267-5),
##' [link to preprint](https://www.biorxiv.org/content/10.1101/665307v5)
##'
##' @examples
##' data("feat2")
##' sce <- as(feat2[[3]], "SingleCellExperiment")
##' pcaSCoPE2(sce)
##'
pcaSCoPE2 <- function(object, scale = FALSE, center = FALSE) {
    ## Extract the protein expression matrix
    X <- assay(object)
    ## Compute the weights
    w <- rowSums(cor(t(X))^2)
    ## Compute the PCs (code taken from the SCoPE2 script)
    Xw <- diag(w) %*%  X
    ## Optionally center and/or scale
    if (center)
        Xw <- sweep(Xw, 2, colMeans(Xw), "-")
    if (scale)
        Xw <- sweep(Xw, 2, colSds(Xw), "/")
    Xcor <- cor(Xw)
    eigen(Xcor)
}


normalizeSCeptre <- function(object, i, 
                             batchCol, 
                             channelCol,
                             iterThres = 1.1,
                             name = "normAssay") {
    stopifnot(inherits(object, "QFeatures"))
    
    ## Get a df from the QFeatures object
    x <- longFormat(object[, , i], 
                    colvars = c(batchCol, channelCol))
    x <- x[!is.na(x$value) & x$value != 0, ]
    
    ## Apply the normalization loop
    for (iter in 1:100) {
        message(paste0("Iteration: ", iter))
        value0 <- x$value
        data.frame(x) %>% 
            ## Normalize by batch
            ## 1. Calculate median for each protein in each batch
            group_by_at(.vars = c(batchCol, "rowname")) %>%
            mutate(meds = median(value, na.rm = TRUE)) %>%
            # 2. Calculate the factors needed for a median shift
            group_by_at("rowname") %>%
            mutate(meansTot = median(meds, na.rm = TRUE)) %>%
            group_by_at(c(batchCol, "rowname")) %>%
            mutate(factors = meds / meansTot) %>%
            # 3. Apply factors
            ungroup() %>%
            mutate(value = value / factors) %>%
            ## Normalize by channel
            ## 1. Calculate median for each protein in each sample
            group_by_at(.vars = c(channelCol, "rowname")) %>%
            mutate(meds = median(value, na.rm = TRUE)) %>%
            # 2. Calculate the factors needed for a median shift
            group_by_at(.vars = "rowname") %>%
            mutate(meansTot = median(meds, na.rm = TRUE)) %>%
            group_by_at(.vars = c(channelCol, "rowname")) %>%
            mutate(factors = meds / meansTot) %>%
            # 3. Apply factors
            ungroup() %>%
            mutate(value = value / factors) ->
            x
        
        current <- abs(max(x$value - value0))
        message(paste0("Current convergence: ", current))
        if (current <= iterThres)
            break()
    }
    ## Format the data as a matrix
    x[, c("rowname", "primary", "value")] %>%
        pivot_wider(id_cols = "rowname", 
                    names_from = "primary", 
                    values_from = "value") %>%
        column_to_rownames("rowname") %>%
        as.matrix ->
        x
    ## Insert the normalized data in the QFeatures object
    sce <- scp[[i]][rownames(x), ]
    assay(sce) <- x
    object <- addAssay(object, 
                       y = sce,
                       name = name)
    addAssayLink(object, 
                 from = i,
                 to = name,
                 varFrom = "Accession",
                 varTo = "Accession")
}
