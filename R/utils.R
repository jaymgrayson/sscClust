#' Correlation calculation. use BLAS and data.table to speed up.
#'
#' @importFrom data.table frank
#' @importFrom RhpcBLASctl omp_get_num_procs omp_set_num_threads
#' @param x matrix; input data, rows for variable (genes), columns for observations (cells).
#' @param y matrix; input data, rows for variable (genes), columns for observations (cells) (default: NULL)
#' @param method character; method used. (default: "pearson")
#' @param nthreads integer; number of threads to use. if NULL, automatically detect the number. (default: NULL)
#' @details calcualte the correlation among variables(rows)
#' @return correlation coefficient matrix among rows
cor.BLAS <- function(x,y=NULL,method="pearson",nthreads=NULL)
{
  if(is.null(nthreads))
  {
    nprocs <- RhpcBLASctl::omp_get_num_procs()
    RhpcBLASctl::omp_set_num_threads(max(nprocs-1,1))
  }else{
    RhpcBLASctl::omp_set_num_threads(nthreads)
  }
  cor.pearson <- function(x,y=NULL)
  {
    if(is.null(y)){
      x = x - rowMeans(x)
      x = x / sqrt(rowSums(x^2))
      ### cause 'memory not mapped' :( ; and slower in my evaluation: 38 sec .vs. 12 sec.
      #x.cor = tcrossprod(x)
      x.cor = x %*% t(x)
      return(x.cor)
    }else{
      x = x - rowMeans(x)
      x = x / sqrt(rowSums(x^2))
      y = y - rowMeans(y)
      y = y / sqrt(rowSums(y^2))
      #xy.cor <- tcrossprod(x,y)
      xy.cor <- x %*% t(y)
      return(xy.cor)
    }
  }
  x <- as.matrix(x)
  if(!is.matrix(x)){
    warning("x is not like a matrix")
    return(NULL)
  }
  if(!is.null(y)){
    y <- as.matrix(y)
    if(!is.matrix(y)){
      warning("y is not like a matrix")
      return(NULL)
    }
  }
  if(method=="pearson"){
    return(cor.pearson(x,y))
  }else if(method=="spearman"){
    if(is.null(y)){
      return(cor.pearson(t(apply(x, 1, data.table::frank, na.last="keep"))))
    }else{
      return(cor.pearson(t(apply(x, 1, data.table::frank, na.last="keep")),
                         t(apply(y, 1, data.table::frank, na.last="keep"))))
    }
  }else{
    warning("method must be pearson or spearman")
    return(NULL)
  }
}


#' dispaly message with time stamp
#' @param msg characters; message to display
loginfo <- function(msg) {
  timestamp <- sprintf("%s", Sys.time())
  msg <- paste0("[",timestamp, "] ", msg,"\n")
  cat(msg)
}


#' Find the knee point of the scree plot
#'
#' @param pcs principal component values sorted decreasingly
#' @details Given sorted decreasingly PCs, find the knee point which have the largest distance to
#' the line defined by the first point and the last point in the scree plot
#' @return index of the knee plot
findKneePoint <- function(pcs)
{
  npts <- length(pcs)
  if(npts<=3){
    return(npts)
  }else{
    P1 <- c(1,pcs[1])
    P2 <- c(npts,pcs[npts])
    v1 <- P1 - P2
    dd <- sapply(2:(npts-1),function(i){
      Pi <- c(i, pcs[i])
      v2 <- Pi - P1
      m <- cbind(v1,v2)
      d <- abs(det(m))/sqrt(sum(v1*v1))
    })
    return(which.max(dd))
  }
}


####### differential expression
#' differential expression analysis
#'
#' @importFrom plyr ldply
#' @importFrom stats aov TukeyHSD
#' @importFrom RhpcBLASctl omp_set_num_threads
#' @importFrom doParallel registerDoParallel
#' @param xdata data frame or matrix; rows for genes and columns for samples
#' @param xlabel factor; cluster label of the samples, with length equal to the number of columns in xdata
#' @param batch factor; covariate. (default: NULL)
#' @param out.prefix character; if not NULL, write the result to the file(s). (default: NULL)
#' @param mod character;
#' @param F.FDR.THRESHOLD numeric; threshold of the adjusted p value of F-test. (default: 0.01)
#' @param HSD.FDR.THRESHOLD numeric; threshold of the adjusted p value of HSD-test (default: 0.01)
#' @param HSD.FC.THRESHOLD numeric; threshold of the absoute diff of HSD-test (default: 1)
#' @param verbose logical; whether output all genes' result. (default: F)
#' @param n.cores integer; number of cores used, if NULL it will be determined automatically (default: NULL)
#' @param gid.mapping named character; gene id to gene symbol mapping. (default: NULL)
#' @return List with the following elements:
#' \item{aov.out}{data.frame, test result of all genes (rownames of xdata)}
#' \item{aov.out.sig}{format as aov.out, but only significant genes. }
findDEGenesByAOV <- function(xdata,xlabel,batch=NULL,out.prefix=NULL,mod=NULL,
                             F.FDR.THRESHOLD=0.01,
                             HSD.FDR.THRESHOLD=0.01,
                             HSD.FC.THRESHOLD=1,
                             verbose=F,n.cores=NULL,
                             gid.mapping=NULL)
{
  clustNames <- unique(xlabel)
  xdata <- as.matrix(xdata)
  ### check rownames and colnames
  if(is.null(rownames(xdata))){
    stop("the xdata does not have rownames!!!")
  }
  if(length(table(xlabel))<2){
    return(NULL)
    #return(list(aov.out=ret.df,aov.out.sig=ret.df.sig))
  }
  if(!is.null(gid.mapping) && is.null(names(gid.mapping))) { names(gid.mapping)=gid.mapping }
  ###
  ## avoid conflict between threaded BLAs and foreach
  RhpcBLASctl::omp_set_num_threads(1)
  registerDoParallel(cores = n.cores)
  ret <- ldply(rownames(xdata),function(v){
    if(is.null(batch)){
        aov.out <- aov(y ~ g,data=data.frame(y=xdata[v,],g=xlabel))
    }else{        
        aov.out <- aov(y ~ g+b,data=data.frame(y=xdata[v,],g=xlabel,b=batch))
    }
    aov.out.s <- summary(aov.out)
    t.res.f <- unlist(aov.out.s[[1]]["g",c("F value","Pr(>F)")])
    aov.out.hsd <- TukeyHSD(aov.out)
    hsd.name <- rownames(aov.out.hsd$g)
    t.res.hsd <- c(aov.out.hsd$g[,"diff"],aov.out.hsd$g[,"p adj"])
    t.res.hsd.minP <- min(aov.out.hsd$g[,"p adj"])
    j <- which.min(aov.out.hsd$g[,"p adj"])
    t.res.hsd.minPDiff <- if(is.na(t.res.hsd.minP)) NaN else aov.out.hsd$g[j,"diff"]
    t.res.hsd.minPCmp <- if(is.na(t.res.hsd.minP)) NaN else rownames(aov.out.hsd$g)[j]
    ## whether cluster specific ?
    t.res.spe  <-  sapply(clustNames,function(v){ all( aov.out.hsd$g[grepl(v,hsd.name,perl=T),"p adj"] < HSD.FDR.THRESHOLD )  })
    ## wheter up across all comparison ?
    is.up <- sapply(clustNames,function(v){  all( aov.out.hsd$g[grepl(paste0(v,"-"),hsd.name),"diff"]>0 ) & all( aov.out.hsd$g[grepl(paste0("-",v),hsd.name),"diff"]<0 ) })
    is.down <- sapply(clustNames,function(v){  all( aov.out.hsd$g[grepl(paste0(v,"-"),hsd.name),"diff"]<0 ) & all( aov.out.hsd$g[grepl(paste0("-",v),hsd.name),"diff"]>0 ) })
    is.clusterSpecific <- (sum(t.res.spe,na.rm = T) == 1)
    if(is.clusterSpecific){
      t.res.spe.lable <- names(which(t.res.spe))
      if(is.up[t.res.spe.lable]) {
        t.res.spe.direction <- "UP"
      }else if(is.down[t.res.spe.lable]) {
        t.res.spe.direction <- "DOWN"
      }else{
        t.res.spe.direction <- "INCONSISTANT"
      }
    }else{
      t.res.spe.lable <- "NA"
      t.res.spe.direction <- "NA"
    }
    dat.ret <- NULL
    if(!is.null(mod) && mod=="cluster.specific") {
      dat.ret <- structure(c(t.res.f,t.res.hsd,t.res.hsd.minP,t.res.hsd.minPDiff,t.res.hsd.minPCmp,
                             t.res.spe,is.clusterSpecific,t.res.spe.lable,t.res.spe.direction),
                           names=c("F","F.pvalue",paste0("HSD.diff.",hsd.name),paste0("HSD.padj.",hsd.name),
                                   "HSD.padj.min","HSD.padj.min.diff","HSD.padj.min.cmp",
                                   paste0("cluster.specific.",clustNames),"is.clusterSpecific","cluster.lable","cluster.direction"))
    }else{
      dat.ret <- structure(c(t.res.f,t.res.hsd,t.res.hsd.minP,t.res.hsd.minPDiff,t.res.hsd.minPCmp),
                           names=c("F","F.pvalue",paste0("HSD.diff.",hsd.name),paste0("HSD.padj.",hsd.name),
                                   "HSD.padj.min","HSD.padj.min.diff","HSD.padj.min.cmp"))
    }
    return(dat.ret)
  },.progress = "none",.parallel=T)
  #print(str(ret))

  if(!is.null(gid.mapping)){
    cnames <- gid.mapping[rownames(xdata)]
  }else{
    cnames <- rownames(xdata)
  }
  f.cnames.na <- which(is.na(cnames))
  cnames[f.cnames.na] <- rownames(xdata)[f.cnames.na]
  ret.df <- data.frame(geneID=rownames(xdata),geneSymbol=cnames,stringsAsFactors=F)
  ret.df <- cbind(ret.df,ret)
  rownames(ret.df) <- rownames(xdata)
  #print(str(ret.df))
  ## type conversion
  if(is.null(mod)){
    i <- 3:(ncol(ret.df)-1)
    ret.df[i]<-lapply(ret.df[i],as.numeric)
  }else{
    i <- 3:(ncol(ret.df)-(4+length(clustNames)))
    ret.df[i]<-lapply(ret.df[i],as.numeric)
    i <- (ncol(ret.df)-(length(clustNames)+2)):(ncol(ret.df)-2)
    ret.df[i]<-lapply(ret.df[i],as.logical)
  }
  ## adjust F test's p value
  ret.df$F.adjp <- 1
  ret.df.1 <- subset(ret.df,!is.na(F.pvalue))
  ret.df.1$F.adjp <- p.adjust(ret.df.1[,"F.pvalue"],method = "BH")
  ret.df.2 <- subset(ret.df,is.na(F.pvalue))
  ret.df <- rbind(ret.df.1,ret.df.2)
  ret.df <- ret.df[order(ret.df$F.adjp,-ret.df$F,ret.df$HSD.padj.min),]
  ### select
  ret.df.sig <- subset(ret.df,F.adjp<F.FDR.THRESHOLD & HSD.padj.min<HSD.FDR.THRESHOLD & abs(HSD.padj.min.diff)>=HSD.FC.THRESHOLD)
  ### output
  if(!is.null(out.prefix)){
    write.table(ret.df.sig,file = sprintf("%s.aov.sig.txt",out.prefix),quote = F,row.names = F,col.names = T,sep = "\t")
    if(verbose){
      write.table(ret.df,file = sprintf("%s.aov.txt",out.prefix),quote = F,row.names = F,col.names = T,sep = "\t")
    }
  }
  #print(str(ret.df))
  return(list(aov.out=ret.df,aov.out.sig=ret.df.sig))
}

#' calculate the AUC of one gene, using it as a classifier. code from SC3
#' @importFrom ROCR prediction performance
#' @importFrom stats aggregate wilcox.test
#' @param gene numeric; expression profile of one gene across samples
#' @param labels character; clusters of the samples belong to
#' @param use.rank logical; using the expression value itself or convert to rank value. (default: TRUE)
getAUC <- function(gene, labels,use.rank=T)
{
    requireNamespace("ROCR")

    if(use.rank){
        score <- rank(gene)
    }else{
        score <- gene
    }
    # Get average score for each cluster
    ms <- aggregate(score ~ labels, FUN = mean)
    # Get cluster with highest average score
    posgroup <- ms[ms$score == max(ms$score), ]$labels
    # Return negatives if there is a tie for cluster with highest average score
    # (by definition this is not cluster specific)
    if(length(posgroup) > 1) {
        return (c(-1,-1,1))
    }
    # Create 1/0 vector of truths for predictions, cluster with highest
    # average score vs everything else
    truth <- as.numeric(labels == posgroup)
    #Make predictions & get auc using RCOR package.
    pred <- prediction(score,truth)
    val <- unlist(performance(pred,"auc")@y.values)
    pval <- suppressWarnings(wilcox.test(score[truth == 1],
                                         score[truth == 0])$p.value)
    return(c(val,posgroup,pval))
}

#' For each gene, calculate the frequency of cells in each clusters are expressed.
#' @importFrom RhpcBLASctl omp_set_num_threads
#' @importFrom doParallel registerDoParallel
#' @importFrom plyr ldply
#' @param exp.bin numeric; binarized expression matrix, rows for genes and columns for samples. value 1 means expressed.
#' @param group character; clusters of the samples belong to
#' @param n.cores integer; number of cores used, if NULL it will be determined automatically (default: NULL)
expressedFraction <- function(exp.bin,group,n.cores=NULL){
    requireNamespace("plyr")
    requireNamespace("doParallel")

    RhpcBLASctl::omp_set_num_threads(1)
    registerDoParallel(cores = n.cores)
    out.res <- ldply(rownames(exp.bin),function(v){
                .res <- aggregate(exp.bin[v,],by=list(group),FUN=function(x){ sum(x==1)/length(x) })
                structure(.res[,2],names=.res[,1])
			},.progress = "none",.parallel=T)
    rownames(out.res) <- rownames(exp.bin)
    colnames(out.res) <- sprintf("HiFrac.%s",colnames(out.res))
    out.res <- as.matrix(out.res)
    return(out.res)
}

#' For each gene, calculate the average expression of the expressor.
#' @importFrom RhpcBLASctl omp_set_num_threads
#' @importFrom doParallel registerDoParallel
#' @importFrom plyr ldply
#' @param exp.bin numeric; binarized expression matrix, rows for genes and columns for samples. value 1 means expressed.
#' @param exp.norm numeric; expression matrix, rows for genes and columns for samples. original version of exp.bin.
#' @param group character; clusters of the samples belong to
#' @param n.cores integer; number of cores used, if NULL it will be determined automatically (default: NULL)
expressedFraction.HiExpressorMean <- function(exp.bin,exp.norm,group,n.cores=NULL){
    requireNamespace("plyr")
    requireNamespace("doParallel")

    RhpcBLASctl::omp_set_num_threads(1)
    registerDoParallel(cores = n.cores)
    exp.bin[exp.bin<1] <- 0
    .exp <- exp.bin*exp.norm
    out.res <- ldply(rownames(.exp),function(v){
                .n <- aggregate(exp.bin[v,],by=list(group),FUN=function(x){ sum(x==1) })
                .res <- aggregate(.exp[v,],by=list(group),FUN=function(x){ sum(x) })
                structure(.res[,2]/.n[,2],names=.res[,1])
			},.progress = "none",.parallel=T)
    rownames(out.res) <- rownames(exp.bin)
    colnames(out.res) <- sprintf("AvgHiExpr.%s",colnames(out.res))
    out.res <- as.matrix(out.res)
    return(out.res)
}

####### classification functions

#' Wraper for running random forest classifier
#'
#' @importFrom varSelRF varSelRF
#' @importFrom stats predict
#' @param xdata data frame or matrix; data used for training, with sample id in rows and variables in columns
#' @param xlabel factor; classification label of the samples, with length equal to the number of rows in xdata
#' @param ydata data frame or matrix; data to be predicted the label, same format as xdata
#' @param do.norm logical; whether perform Z score normalization on data
#' @param ntree integer; parameter of varSelRF::varSelRF
#' @param ntreeIterat integer; parameter of varSelRF::varSelRF
#' @return List with the following elements:
#' \item{ylabel}{ppredicted labels of the samples in ydata}
#' \item{rfsel}{trained model; output of varSelRF()}
run.RF <- function(xdata, xlabel, ydata, do.norm=F, ntree = 500, ntreeIterat = 200)
{
  #require("varSelRF")
  #require("randomForest")
  f.g <- intersect(colnames(xdata),colnames(ydata))
  xdata <- xdata[,f.g,drop=F]
  ydata <- ydata[,f.g,drop=F]
  ### normalization
  if(do.norm){
    xdata <- scale(xdata,center = T,scale = T)
    ydata <- scale(ydata,center = T,scale = T)
  }
  ### random forest
  rfsel <- varSelRF::varSelRF(xdata, xlabel,
                              ntree = ntree, ntreeIterat = ntreeIterat,
                              whole.range = FALSE,keep.forest = T)
  #rfsel$selected.vars %>% str %>% print
  #rfsel$initialImportances %>% head %>% print
  #rfsel$rf.model$confusion %>% print
  yres <- predict(rfsel$rf.model, newdata = ydata[,rfsel$selected.vars],type = "prob")
  cls.set <- colnames(yres)
  ylabel <- apply(yres,1,function(x){ cls.set[which.max(x)] })
  names(ylabel) <- rownames(ydata)
  return(list("ylabel"=ylabel,"rfsel"=rfsel,"yres"=yres))
}

#' Wraper for running svm
#'
#' @importFrom e1071 svm
#' @importFrom stats predict
#' @param xdata data frame or matrix; data used for training, with sample id in rows and variables in columns
#' @param xlabel factor; classification label of the samples, with length equal to the number of rows in xdata
#' @param ydata data frame or matrix; data to be predicted the label, same format as xdata
#' @param kern character; which kernel to use, can be one of linear, polynomial, radial and sigmoid (default: "linear")
#' @return List with the following elements:
#' \item{ylabel}{ppredicted labels of the samples in ydata}
#' \item{rfsel}{trained model; output of varSelRF()}
run.SVM <- function(xdata, xlabel, ydata,kern="linear")
{
  f.g <- intersect(colnames(xdata),colnames(ydata))
  xdata <- xdata[,f.g,drop=F]
  ydata <- ydata[,f.g,drop=F]
  model <- e1071::svm(xdata, xlabel, kernel = kern)
  ylabel <- predict(model, newdata=ydata)
  names(ylabel) <- rownames(ydata)
  return(list("ylabel"=ylabel,"svm"=model))
}

#' Wraper for running random forest classifier
#' @importFrom class knn
#' @param xdata data frame or matrix; data used for training, with sample id in rows and variables in columns
#' @param xlabel factor; classification label of the samples, with length equal to the number of rows in xdata
#' @param ydata data frame or matrix; data to be predicted the label, same format as xdata
#' @param k parameter k of function knn() (default: 1)
#' @return List with the following elements:
#' \item{ylabel}{ppredicted labels of the samples in ydata}
run.KNN <- function(xdata,xlabel,ydata,k=1)
{
  #require("class")
  f.g <- intersect(colnames(xdata),colnames(ydata))
  ylabel <- class::knn(xdata[,f.g,drop=F], ydata[,f.g,drop=F], as.factor(xlabel), k = k, l = 0, prob = FALSE, use.all = TRUE)
  names(ylabel) <- rownames(ydata)
  return(list("ylabel"=ylabel))
}

#' Wraper for running Rtsne
#' @importFrom Rtsne Rtsne
#' @importFrom stats prcomp
#' @param idata matrix; expression data with sample id in rows and variables in columns
#' @param tSNE.usePCA whether perform PCA before tSNE (default: T)
#' @param tSNE.perplexity perplexity parameter of tSNE (default: 30)
#' @param n.cores integer; number of cores used, if NULL it will be determined automatically (default: NULL)
#' @param out.prefix character; output prefix (default: NULL)
#' @return If successful same as the return value of Rtsne(); otherwise NULL
run.tSNE <- function(idata,tSNE.usePCA=T,tSNE.perplexity=30,method="Rtsne",n.cores=NULL,out.prefix=NULL,...){
  ret <- NULL
  if(is.null(n.cores)){ n.cores <- 1 }
  if(method=="Rtsne"){
      tryCatch({
        ret <- Rtsne::Rtsne(idata, pca = tSNE.usePCA, num_threads=n.cores, perplexity = tSNE.perplexity)$Y
      },error=function(e){
        #cat("Perplexity is too large; try to use smaller perplexity 5\n")
      })
      if(is.null(ret)){
        tryCatch({
          ret <- Rtsne::Rtsne(idata, pca = tSNE.usePCA, num_threads=n.cores, perplexity = 5)$Y
        },error=function(e){ print("Error occur when using perplexity 5"); print(e); e })
      }
  }else if(method=="FIt-SNE"){
      if(tSNE.usePCA){
        pca.res <- prcomp(idata)
        pca.npc <- min(50,ncol(pca.res$x))
        X <- pca.res$x[,1:pca.npc,drop=F]
      }else{
        X <- idata
      }
      ret <- fftRtsne(X,perplexity=tSNE.perplexity,nthreads=n.cores,out_prefix=out.prefix)
  }
  return(ret)
}


#' Wraper for running SC3
#' @importFrom SC3 sc3 sc3_plot_consensus sc3_plot_silhouette sc3_plot_cluster_stability sc3_plot_markers
#' @importFrom plyr llply
#' @importFrom RhpcBLASctl omp_set_num_threads
#' @importFrom doParallel registerDoParallel
#' @param obj object of \code{singleCellExperiment} class
#' @param assay.name character; which assay (default: "exprs")
#' @param out.prefix character, output prefix
#' @param n.cores integer, number of cors to use. (default: 8)
#' @param ks integer vector, number of clusters. (default: 2:10)
#' @param SC3.biology logical, SC3 parameter, whether calcualte biology. (default: T)
#' @param SC3.markerplot.width integer, SC3 parameter, with of the marker plot (default: 15)
#' @param verbose logical, whether verbose output. (default: F)
#' @details Run SC3 clustering pipeline
#' @return an object of \code{SingleCellExperiment} class with cluster labels and other info added.
#' @export
run.SC3 <- function(obj,assay.name="exprs",out.prefix=NULL,n.cores=8,ks=2:10,SC3.biology=T,SC3.markerplot.width=15,verbose=F)
{
  rownames.old <- rownames(obj)
  #### current SC3 need feature_symbol as rownames
  if(!"feature_symbol" %in% names(rowData(obj))){ rowData(obj)$feature_symbol <- rownames.old }
  rownames(obj) <- rowData(obj)$feature_symbol
  #### current SC3 use logcounts as dataset
  psu.logcounts <- F
  if(!"logcounts" %in% assayNames(obj)){
    assay(obj,"logcounts") <- assay(obj,assay.name)
    psu.logcounts <- T
  }
  #### current SC3 usde counts also
  psu.counts <- F
  if(!"counts" %in% assayNames(obj)){
    assay(obj,"counts") <- assay(obj,assay.name)
    psu.counts <- T
  }
  #### run
  obj <- sc3(obj, ks = ks, biology = SC3.biology, n_cores = n.cores,svm_max = 50000000,gene_filter = F)
  if(!is.null(out.prefix))
  {
    RhpcBLASctl::omp_set_num_threads(1)
    registerDoParallel(cores = n.cores)
    tryCatch({
      no.ret <- llply(ks,function(k){
        ###### sc3_plot_consensus is slow, not sure why
        png(sprintf("%s.consensus.k%d.png",out.prefix,k),width = 600,height = 480)
        sc3_plot_consensus(obj, k = k,  show_pdata = c( "sampleType", sprintf("sc3_%d_clusters",k),
                                                        sprintf("sc3_%s_log2_outlier_score",k)))
        dev.off()
        pdf(sprintf("%s.silhouette.k%d.pdf",out.prefix,k),width = 6,height = 6)
        sc3_plot_silhouette(obj, k = k)
        dev.off()
        p <- sc3_plot_cluster_stability(obj, k = k)
        ggsave(sprintf("%s.stability.k%d.pdf",out.prefix,k),width = 4,height = 3)
        if(SC3.biology){
          sc3_plot_markers(obj, k = k,auroc = 0.7,plot.extra.par = list(filename=sprintf("%s.markers.k%d.pdf",out.prefix,k),
                                                                        width=SC3.markerplot.width),
                           show_pdata = c( "sampleType",sprintf("sc3_%d_clusters",k), sprintf("sc3_%s_log2_outlier_score",k)))
        }
      },.progress = "none",.parallel=T)
    },error=function(e){
      cat(sprintf("Error occur in llply(ks,...).\n"))
      print(e)
    })
    if(verbose){ save(obj,file=sprintf("%s.verbose.sce.RData",out.prefix)) }
  }
  rownames(obj) <- rownames.old
  #### current SC3 use logcounts as dataset
  if(psu.logcounts){ assay(obj,"logcounts") <- NULL }
  #### current SC3 usde counts also
  if(psu.counts){ assay(obj,"counts") <- NULL }
  return(obj)
}

#' Wraper for running ZinbWave
#' @importFrom zinbwave zinbFit
#' @importFrom RhpcBLASctl omp_set_num_threads
#' @importFrom BiocParallel MulticoreParam
#' @param obj object of \code{singleCellExperiment} class
#' @param assay.name character; which assay to use for select genes (default: "exprs")
#' @param vgene vector; only consider those specified genes if set. (default: NULL)
#' @param out.prefix character, output prefix
#' @param n.cores integer, number of cors to use. (default: 8)
#' @param zinbwave.K integer, zinbwave parameter, number of latent variables. (default: 20)
#' @param zinbwave.X character, zinbwave parameter, cell-level covariates. (default: "~patient")
#' @param verbose logical, whether verbose output. (default: F)
#' @details Run ZinbWave fitting
#' @return an object of class ZinbModel
#' @export
run.zinbWave <- function(obj,assay.name="exprs", vgene=NULL,out.prefix="./zinbwave",n.cores=8,
                         zinbwave.K=20,
                         zinbwave.X="~patient",verbose=F)
{
  if(is.null(vgene)){
    obj <- ssc.variableGene(obj,method = "HVG.sd",sd.n = 1500,assay.name = assay.name)
    #vgene <- metadata(obj)$ssc$variable.gene$sd
    vgene <- rowData(obj)[["HVG.sd"]]
  }
  RhpcBLASctl::omp_set_num_threads(1)
  #### fitting
  obj.zinb <- zinbFit(obj[vgene,], K=zinbwave.K, X=zinbwave.X, epsilon=1000,BPPARAM=MulticoreParam(n.cores),verbose=verbose)
  return(obj.zinb)
}

#' Wraper for running FIt-SNE. Code from KlugerLab (https://github.com/KlugerLab/FIt-SNE)
#' @param X matrix; samples in rows and variables in columns
#' @param dims integer; dimentionality of the returned matrix
#' @param perplexity double; perplexity parameter of tSNE (effective nearest neighbours)
#' @param theta double; theta
#' @param max_iter integer; max_iter
#' @param out_prefix character; temporary files prefix for fast_tsne (default: NULL)
#' @param fast_tsne_path character; full path of the installed fast_tsne programe (default: NULL)
#' @param nthreads integer; number of threads (default: 0)
#' @details Run FIt-SNE
#' @return a matrix with samples in rows and tSNE coordinate in columns
#' @export
fftRtsne <- function(X,
		     dims=2, perplexity=30, theta=0.5,
		     #check_duplicates=TRUE,
		     max_iter=1000,
		     fft_not_bh = TRUE,
		     ann_not_vptree = TRUE,
		     stop_early_exag_iter=250,
		     exaggeration_factor=12.0, no_momentum_during_exag=FALSE,
		     start_late_exag_iter=-1.0,late_exag_coeff=1.0,
             mom_switch_iter=250, momentum=.5, final_momentum=.8, learning_rate=200,
		     n_trees=50, search_k = -1,rand_seed=-1,
		     nterms=3, intervals_per_integer=1, min_num_intervals=50,
		     K=-1, sigma=-30, initialization=NULL,
		     #data_path=NULL, result_path=NULL,
             out_prefix=NULL,
		     load_affinities=NULL,
		     fast_tsne_path=NULL, nthreads=0, perplexity_list = NULL,get_costs = FALSE, ... )
{
  data_path <- tempfile(pattern=sprintf("%s.fftRtsne_data_",if(is.null(out_prefix)) "" else out_prefix),
                        fileext='.dat')
  result_path <- tempfile(pattern=sprintf("%s.fftRtsne_result_",if(is.null(out_prefix)) "" else out_prefix),
                          fileext='.dat')
  if (is.null(fast_tsne_path)) {
    fast_tsne_path <- system2('which', 'fast_tsne', stdout=TRUE)
  }
  fast_tsne_path <- normalizePath(fast_tsne_path)
  if (!file_test('-x', fast_tsne_path)) {
      warning(sprintf("%s does not exist or is not executable; check your fast_tsne_path parameter\n",
                      fast_tsne_path))
      return(NULL)
      #stop(fast_tsne_path, " does not exist or is not executable; check your fast_tsne_path parameter")
  }

  is.wholenumber <- function(x, tol = .Machine$double.eps^0.5)  abs(x - round(x)) < tol

  if (!is.numeric(theta) || (theta<0.0) || (theta>1.0) ) {
      warning("Incorrect theta.")
      return(NULL)
      #stop("Incorrect theta.")
  }
  if (nrow(X) - 1 < 3 * perplexity) {
      warning("Perplexity is too large.")
      return(NULL)
      #stop("Perplexity is too large.")
  }
  if (!is.matrix(X)) {
      warning("Input X is not a matrix")
      return(NULL)
      #stop("Input X is not a matrix")
  }
  if (!(max_iter>0)) {
      warning("Incorrect number of iterations.")
      return(NULL)
      #stop("Incorrect number of iterations.")
  }
  if (!is.wholenumber(stop_early_exag_iter) || stop_early_exag_iter<0) {
      warning("stop_early_exag_iter should be a positive integer")
      return(NULL)
      #stop("stop_early_exag_iter should be a positive integer")
  }
  if (!is.numeric(exaggeration_factor)) {
      warning("exaggeration_factor should be numeric")
      return(NULL)
      #stop("exaggeration_factor should be numeric")
  }
  if (!is.wholenumber(dims) || dims<=0) {
      warning("Incorrect dimensionality.")
      return(NULL)
      #stop("Incorrect dimensionality.")
  }
  if (search_k == -1) {
      if (perplexity>0) {
          search_k = n_trees*perplexity*3
      } else if (perplexity==0) {
          search_k = n_trees*max(perplexity_list)*3
      } else {
          search_k = n_trees*K*3
      }
  }

  if (fft_not_bh){
      nbody_algo = 2;
  }else{
      nbody_algo = 1;
  }

  if (is.null(load_affinities)) {
      load_affinities = 0;
  } else {
      if (load_affinities == 'load') {
          load_affinities = 1;
      } else if (load_affinities == 'save') {
          load_affinities = 2;
      } else {
          load_affinities = 0;
      }
  }
  
  if (ann_not_vptree){
      knn_algo = 1;
  }else{
      knn_algo = 2;
  }
  tX = c(t(X))

  f <- file(data_path, "wb")
  n = nrow(X);
  D = ncol(X);
  writeBin(as.integer(n), f,size= 4)
  writeBin( as.integer(D),f,size= 4)
  writeBin( as.numeric(theta), f,size= 8) #theta
  writeBin( as.numeric(perplexity), f,size= 8) #theta

  if (perplexity == 0) {
      writeBin( as.integer(length(perplexity_list)), f, size=4)
      writeBin( perplexity_list, f)
  }

  writeBin( as.integer(dims), f,size=4) #theta
  writeBin( as.integer(max_iter),f,size=4)
  writeBin( as.integer(stop_early_exag_iter),f,size=4)
  writeBin( as.integer(mom_switch_iter),f,size=4)
  writeBin( as.numeric(momentum),f,size=8)
  writeBin( as.numeric(final_momentum),f,size=8)
  writeBin( as.numeric(learning_rate),f,size=8)
  writeBin( as.integer(K),f,size=4) #K
  writeBin( as.numeric(sigma), f,size=8) #sigma
  writeBin( as.integer(nbody_algo), f,size=4)  #not barnes hut
  writeBin( as.integer(knn_algo), f,size=4)
  writeBin( as.numeric(exaggeration_factor), f,size=8) #compexag
  writeBin( as.integer(no_momentum_during_exag), f,size=4)
  writeBin( as.integer(n_trees), f,size=4)
  writeBin( as.integer(search_k), f,size=4)
  writeBin( as.integer(start_late_exag_iter), f,size=4)
  writeBin( as.numeric(late_exag_coeff), f,size=8)
  
  writeBin( as.integer(nterms), f,size=4)
  writeBin( as.numeric(intervals_per_integer), f,size=8)
  writeBin( as.integer(min_num_intervals), f,size=4)
  tX = c(t(X))
  writeBin( tX, f)
  writeBin( as.integer(rand_seed), f,size=4)
  writeBin( as.integer(load_affinities), f,size=4)
  if (! is.null(initialization)){ writeBin( c(t(initialization)), f) }
  close(f)

  flag= system2(command=fast_tsne_path, args=c(data_path, result_path, nthreads));
  if (flag != 0) {
      warning('tsne call failed')
      return(NULL)
      #stop('tsne call failed');
  }
  f <- file(result_path, "rb")
  n <- readBin(f, integer(), n=1, size=4);
  d <- readBin(f, integer(), n=1, size=4);
  Y <- readBin(f, numeric(), n=n*d);
  Y <- t(matrix(Y, nrow=d));
  if (get_costs ) {
      costs <- readBin(f, numeric(), n=max_iter,size=8);
      Yout <- list( Y=Y, costs=costs);
  }else {
      Yout <- Y;
  }
  close(f)
  file.remove(data_path)
  file.remove(result_path)
  return(Yout)
}

#' Modified from limma::removeBatchEffect, a little different design matrix
#' @param x matrix; samples in columns and variables in rows
#' @param batch character; batch vector (default: NULL)
#' @param covariates double; other covariates to adjust (default: NULL)
#' @details Modified from limma::removeBatchEffect, a little different design matrix
#' @return a matrix with dimention as input ( samples in rows and variables in columns)
#' @export
simple.removeBatchEffect <- function (x, batch = NULL, covariates = NULL, ...)
{
    if (is.null(batch) && is.null(covariates))
        return(as.matrix(x))
    if (!is.null(batch)) {
        batch <- as.factor(batch)
        batch <- model.matrix(~batch)
    }
    if (!is.null(covariates))
        covariates <- as.matrix(covariates)
    X.batch <- cbind(batch, covariates)
    fit <- lmFit(x, X.batch, ...)
    beta <- fit$coefficients
    beta[is.na(beta)] <- 0
    ret.V <- as.matrix(x) - beta %*% t(X.batch)
    return(ret.V)
}



