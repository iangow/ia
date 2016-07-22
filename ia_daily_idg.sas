libname taq  '/wrds/taq/sasdata';
libname crsp '/wrds/crsp/sasdata/sd/';
libname issm '/wrds/issm/sasdata';

libname home '.';

options nocenter nonumber nodate ps=30000 ls=150;
*options merror mlogic;


/***************************************************************************************************
Monthly                                                                                
Symbol  Yrmon  lambda_GH   lambda_LSB  lambda_HFV  lambda_sa  lambda_sb  lambda_MRR
                                                                                
CLEANS DATA USING FILTERS DESCRIBED IN NG-RUSTICUS-VERDI JAR08

*****************************************************************************************************/

/*************************************/
/*************************************/
/*        LEE READY ALGORITHM        */
/*************************************/
/*************************************/

%macro LR(delay=,tradesstart=,quotesstart=,endtime=);

  *use TAQ data;

  * -- (i): Get trade data with filters  ---------------- *;
  data trades (drop=corr cond) / view=trades; 
    set taq.ct_&taq_date (keep=symbol date time price size cond corr);
    by symbol date time;
    where &tradesstart<=time<=&endtime and price > 0 and size > 0 
      and corr in (0,1) and missing(cond); 
    pricesize = price * size;* calculate weighted ave. transaction prc in next step;
    if not first.date and abs(price-lag(price))/lag(price) >0.10 then delete;
  run; 

    * -- (ii) Get quote changes ------------------------- *;
  data quotes (drop=mode rename=(bidsiz=bidsize ofrsiz=ofrsize)) / view=quotes; 
    set taq.cq_&taq_date (keep=symbol date time ofr bid mode bidsiz ofrsiz); 
    by symbol date time;
    where &quotesstart<=time<=&endtime and
      bid>0 and ofr>0 and ofr>bid and bidsiz>0 and ofrsiz>0 and mode=12;
    midpoint = (bid+ofr)/2;
    if not first.date and abs(bid-lag(bid))/lag(bid) >0.10 then delete;
    if not first.date and abs(ofr-lag(ofr))/lag(ofr) >0.10 then delete;
    if (ofr-bid)/midpoint >0.2 then delete;
    label midpoint='bid-ask midpoint';
  run;

    * -- (iii): Get weighted prices for trades happening at the same time *;
  proc means data=trades noprint; 
    by symbol date time;
    var pricesize size;
    output out=trades2(rename=(_freq_=n_trades) drop=_type_) 
      sum(pricesize)=pricesize sum(size)=size;
  run;

  proc sql;
    drop view trades;
  quit;
  
    * -- (iv): Compute tick ---------------------------- *;
  data trades2(drop=lagprice lag2price pricesize); 
    set trades2; 
    by symbol date time;
    price = pricesize / size;     * Weighted average transaction price ;
    time = time-&delay;           * Subtract delay seconds from trade time;
    lagprice = lag(price);        * compute variable for tick test *;
    lag2price = lag2(price);      * can be modified to look back further;
    if first.date then do;
      lagprice=.;  lag2price=.;
    end;
    tick=sign(price-lagprice);
    if tick=0 then tick=sign(lagprice-lag2price);
        if first.date then
      do;
        nn=0;
        tick =0;
      end;
    else nn=nn+1;

    if nn < 3 then tick=0;
    if tick = . then tick = 0;
     
    bin1=(pricesize<=5000);
    bin2=(5000<pricesize<=10000);
    bin3=(10000<pricesize<=20000);
    bin4=(20000<pricesize<=50000);
    bin5=(pricesize>50000);
    retain nn;

  run;
  
    * -- (v) Assign as buyer/seller initated as per Lee and Ready ;
    * using quote test and then tick test -------------- *;
  data LRdata (drop= tick midpoint); 
    set trades2 (in=tr) quotes; 
    by symbol date time;
    yrmon=(year(date)*100)+month(date);
    if first.date then do; * reset retained variables for new day;
      mid_point2= .; qspread=.; depth=.;
    end;
    
    if midpoint ne . then do; 
      mid_point2 = midpoint; 
      qspread=ofr-bid;
      depth=ofr*ofrsize+bid*bidsize;
    end;
    
    if tr=1 then do;
      if mid_point2 ne . then do; 
        buyer_init=sign(price-mid_point2);   * Quote test first;
        if buyer_init=0 then buyer_init=tick;* Tick test *;
      end;
      signedorder=buyer_init*size;
      output;
    end;
    retain mid_point2 qspread depth; 
  run;
  
  proc datasets library=work; 
    delete trades2;
  run;
  
  * -- LRdata has 9 vars: symbol, date, time, mid_point2, qspread, price, size, ;
  * buyer_init, signedorder --------- *;
%mend LR;


/********************************************/
/********************************************/
/*        ADVERSE SELECTION MEASURES        */
/********************************************/
/********************************************/

%macro lambdaGH(firmID=,timeID=,dsetin=);
  data GH / view=GH; 
    set &dsetin (keep=symbol date yrmon time price buyer_init signedorder size); 
    by symbol date time; 
    deltaP = price - lag(price);
    deltaD = buyer_init - lag(buyer_init);
    deltaS = signedorder - lag(signedorder);  ***** Change in signed trade size;
    D      = buyer_init;                      ***** Trade Sign;
    S      = signedorder;                     ***** Signed trade size;
    if symbol ^= lag(symbol) or first.date then do;
      deltaP = .;  deltaD = .;  deltaS = .;  D = .;  S = .;
    end;
  run;
  
  data lambda_GH; set _null_; symbol=""; date=.; DeltaD=.; DeltaS=.; D=.; S=.; run;
  options nonotes;
  proc reg data=GH outest=lambda_GH noprint; 
    by symbol date; 
    model deltaP = deltaD deltaS D S; 
  run;
  options notes;

  proc sql;
    create table avg_volume as
    select
      symbol, date, mean(size) as avg_volume, min(date) as first_date, max(date) as last_date 
    from GH group by symbol, date;
    
    create table lambda_GH as select
      a.*, 2*(a.D+a.S*b.avg_volume) as lambda_GH,
         2*(a.deltaD+a.deltaS*b.avg_volume) as lambda_GHother,
          b.first_date, b.last_date
    from lambda_GH as a 
    left join avg_volume as b 
    on a.symbol=b.symbol and a.date=b.date; 
  quit;

  proc sql; drop view GH; drop table avg_volume; quit;
  
%mend lambdaGH;

%macro lambdaMRR(firmID=,timeID=,dsetin=);
  data MRR / view=MRR; 
  set &dsetin (keep=symbol date time yrmon price buyer_init); 
  by symbol date time;
    deltaP = (price - lag(price))/lag(price);
    deltaD = buyer_init - lag(buyer_init);
       lagbuyer_init=lag(buyer_init);
    if symbol ^= lag(symbol) or first.date then do;
      deltaP = .;
             deltaD = .;
        lagbuyer_init=.;
      end;
  run;

  data MRRresids; 
    set _null_;
    symbol="";
    date=.;
    DeltaP=.;
    DeltaD=.;
    AR1resid=.; 
  run;
  
  options nonotes;
  proc reg data=MRR noprint; 
    by symbol date; 
    model buyer_init=lagbuyer_init/noint; 
    output out=MRRresids r=AR1resid; 
  run;
  options notes;

  data lambda_MRR;
    set _null_;
    symbol=""; date=.;
    DeltaD=.; AR1resid=.;
  run;
  
  options nonotes;
  proc reg data=MRRresids outest=lambda_MRR noprint; 
    by symbol date; 
    model deltaP= deltaD AR1resid; 
  run;
  options notes;

  proc sql; 
    drop view MRR;
    drop table MRRresids;
  quit;
  
%mend lambdaMRR;

%macro universe(taq_date=);

  *call Lee-Ready;

  %LR(delay=5,tradesstart="9:45:00"t,quotesstart="9:30:00"t,endtime="16:00:00"t);

  *retain only signed trades;
  data LRdata;
    set LRdata;
    if buyer_init in (-1,1);
  run;

  proc sql; 
    create table count as 
    select unique symbol, date, 
      count(symbol) as Ntrades, 
      avg(size) as EWsize,
      sum((qspread/price)*size)/sum(size) as TWspread, 
      sum((qspread/mid_point2)*size)/sum(size) as TWqspread,
      sum(price*size)/sum(size) as TWprice,
      sum((2*abs(price-mid_point2)/price) *size) / sum(size) as TWespread, 
      avg(qspread/price) as EWspread, 
      avg(qspread/mid_point2) as EWqspread,
      avg(price) as EWprice,
      avg((2*abs(price-mid_point2)/price)) as EWespread, 
      avg(depth) as EWdepth,
      sum(bin1) as bin1, sum(bin2) as bin2, sum(bin3) as bin3, 
      sum(bin4) as bin4, sum(bin5) as bin5
    from LRdata group by symbol, date order by symbol, date; 
  quit;

  *call Adverse Selection measures;
  %lambdaGH(firmID=symbol,  timeID=date,  dsetin=LRdata);
  %lambdaMRR(firmID=symbol,  timeID=date,  dsetin=LRdata);
  proc datasets library=work; delete LRdata; run; 

  *merge measures;
  data home.Lambdadaily&taq_date;
    merge count
      lambda_GH(keep=symbol date lambda_GH lambda_GHother first_date last_date)
      lambda_MRR  (keep=symbol date AR1resid   rename=(AR1resid=lambda_MRR));
      by symbol date;
  run;

  proc datasets library=work; 
    delete lambda_GH lambda_MRR;
  run; 
/*
  filename mailbox email;
  data _null_;
    file mailbox to='igow@hbs.edu' 
    subject='Re: TAQdatav6 program has completed another year of data...';
    x=&taq_date;
    put 'Completed Date ' x ;
  run;
*/
%mend universe;

/************************/
/*    END MACROS    */
/************************/

%put &sysparm;

/* We can invoke the SAS program in the command mode as follows:
     sas ia_daily_idg.sas -sysparm "20060103"
*/
%universe(taq_date=&sysparm);
