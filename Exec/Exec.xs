/* 
 * Filename : exec.xs
 * 
 * Author   : Paul Marquess 
 * Date     : 17th March 1999
 * Version  : 1.03
 *
 */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <fcntl.h>

static int fdebug = 0 ;

#ifndef PERL_VERSION
#include "patchlevel.h"
#define PERL_REVISION	5
#define PERL_VERSION	PATCHLEVEL
#define PERL_SUBVERSION	SUBVERSION
#endif

#if PERL_REVISION == 5 && (PERL_VERSION < 4 || (PERL_VERSION == 4 && PERL_SUBVERSION <= 75 ))

#    define PL_sv_undef		sv_undef
#    define PL_na		na
#    define PL_curcop		curcop
#    define PL_compiling	compiling
#    define PL_rsfp		rsfp

#endif 


#define PIPE_IN(sv)	IoLINES(sv)
#define PIPE_OUT(sv)	IoPAGE(sv)

#define BUF_SV(sv)	IoTOP_GV(sv)
#define BUF_START(sv)	SvPVX((SV*) BUF_SV(sv))
#define BUF_SIZE(sv)	SvCUR((SV*) BUF_SV(sv))
#define BUF_NEXT(sv)	IoFMT_NAME(sv)
#define BUF_END(sv)	(BUF_START(sv) + BUF_SIZE(sv))
#define BUF_OFFSET(sv)  IoPAGE_LEN(sv) 
 
#define SET_LEN(sv,len) \
        do { SvPVX(sv)[len] = '\0'; SvCUR_set(sv, len); } while (0)
 
#define BLOCKSIZE       100

#ifdef WIN32

static int write_started = 0;
static int pipe_pid = 0;

typedef struct {
    SV *	sv;
    int		idx;
#ifdef USE_THREADS
    struct perl_thread *	parent;
#endif
} thrarg;

static void
pipe_write(args)
void *args ;
{
    thrarg *targ = (thrarg *)args;
    SV *sv = targ->sv;
    int idx = targ->idx;
    int    pipe_in  = PIPE_IN(sv) ;
    int    pipe_out = PIPE_OUT(sv) ;
    int rawread_eof = 0;
    int r,w,len;
    free(args);
#ifdef USE_THREADS
    /* use the parent's perl thread context */
    SET_THR(targ->parent);
#endif
    for(;;)
    {       

        /* get some raw data to stuff down the pipe */
	/* But only when BUF_SV is empty */
        if (!rawread_eof && BUF_NEXT(sv) >= BUF_END(sv)) {       
	    /* empty BUF_SV */
	    SvCUR_set((SV*)BUF_SV(sv), 0) ;
            if ((len = FILTER_READ(idx+1, (SV*) BUF_SV(sv), 0)) > 0) {
		BUF_NEXT(sv) = BUF_START(sv);
                if (fdebug)
                    warn ("*pipe_read(%d) Filt Rd returned %d %d [%*s]\n", 
			idx, len, BUF_SIZE(sv), BUF_SIZE(sv), BUF_START(sv)) ;
	     }
             else {
                /* eof, close write end of pipe after writing to it */
		 rawread_eof = 1;
	     }
	}
 
 	/* write down the pipe */
        if ((w = BUF_END(sv) - BUF_NEXT(sv)) > 0) {
	    errno = 0;
            if ((w = write(pipe_out, BUF_NEXT(sv), w)) > 0) {
		BUF_NEXT(sv) += w;
		if (fdebug)
		    warn ("*pipe_read(%d) wrote %d bytes to pipe\n", idx, w) ;
	    }
            else {
                if (fdebug)
                   warn ("*pipe_read(%d) closing pipe_out errno = %d %s\n", 
			idx, errno, Strerror(errno)) ;
                close(pipe_out) ;
		CloseHandle((HANDLE)pipe_pid);
		write_started = 0;
		return;
	    }
	}
	else if (rawread_eof) {
	    close(pipe_out);
	    CloseHandle((HANDLE)pipe_pid);
	    write_started = 0;
	    return;
	}
    }
}

static int
pipe_read(sv, idx, maxlen)
SV  * sv ;
int idx ;
int maxlen ;
{
    int    pipe_in  = PIPE_IN(sv) ;
    int    pipe_out = PIPE_OUT(sv) ;

    int r ;
    int w ;
    int len ;

    if (fdebug)
        warn ("*PIPE_READ(sv=%d, SvCUR(sv)=%d, idx=%d, maxlen=%d\n",
		sv, SvCUR(sv), idx, maxlen) ;

    if (!maxlen)
	maxlen = 1024 ;

    /* just make sure the SV is big enough */
    SvGROW(sv, SvCUR(sv) + maxlen) ;

    if ( !BUF_NEXT(sv) )
        BUF_NEXT(sv) = BUF_START(sv);

    if (!write_started) {
	thrarg *targ = malloc(sizeof(thrarg));
	targ->sv = sv; targ->idx = idx;
#ifdef USE_THREADS
	targ->parent = THR;
#endif
	/* thread handle is closed when pipe_write() returns */
	_beginthread(pipe_write,0,(void *)targ);
	write_started = 1;
    }

    /* try to get data from filter, if any */
    errno = 0;
    len = SvCUR(sv) ;
    if ((r = read(pipe_in, SvPVX(sv) + len, maxlen)) > 0)
    {
	if (fdebug)
	    warn ("*pipe_read(%d) from pipe returned %d [%*s]\n", 
			idx, r, r, SvPVX(sv) + len) ;
	SvCUR_set(sv, r + len) ;
	return SvCUR(sv);
    }

    if (fdebug)
	warn ("*pipe_read(%d) returned %d, errno = %d %s\n", 
		idx, r, errno, Strerror(errno)) ;

    /* close the read pipe on error/eof */
    if (fdebug)
	warn("*pipe_read(%d) -- EOF <#########\n", idx) ;
    close (pipe_in) ; 
    return 0;
}

#else /* !WIN32 */


static int
pipe_read(sv, idx, maxlen)
SV  * sv ;
int idx ;
int maxlen ;
{
    int    pipe_in  = PIPE_IN(sv) ;
    int    pipe_out = PIPE_OUT(sv) ;

    int r ;
    int w ;
    int len ;

    if (fdebug)
        warn ("*PIPE_READ(sv=%d, SvCUR(sv)=%d, idx=%d, maxlen=%d\n",
		sv, SvCUR(sv), idx, maxlen) ;

    if (!maxlen)
	maxlen = 1024 ;

    /* just make sure the SV is big enough */
    SvGROW(sv, SvCUR(sv) + maxlen) ;

    for(;;)
    {       
	if ( !BUF_NEXT(sv) )
            BUF_NEXT(sv) = BUF_START(sv);
        else
        {       
	    /* try to get data from filter, if any */
            errno = 0;
	    len = SvCUR(sv) ;
            if ((r = read(pipe_in, SvPVX(sv) + len, maxlen)) > 0)
	    {
                if (fdebug)
                    warn ("*pipe_read(%d) from pipe returned %d [%*s]\n", 
				idx, r, r, SvPVX(sv) + len) ;
		SvCUR_set(sv, r + len) ;
                return SvCUR(sv);
	    }

            if (fdebug)
                warn ("*pipe_read(%d) returned %d, errno = %d %s\n", 
			idx, r, errno, Strerror(errno)) ;

            if (errno != VAL_EAGAIN)
	    {
		/* close the read pipe on error/eof */
    		if (fdebug)
		    warn("*pipe_read(%d) -- EOF <#########\n", idx) ;
		close (pipe_in) ; 
                return 0;
	    }
        }

        /* get some raw data to stuff down the pipe */
	/* But only when BUF_SV is empty */
        if (BUF_NEXT(sv) >= BUF_END(sv))
        {       
	    /* empty BUF_SV */
	    SvCUR_set((SV*)BUF_SV(sv), 0) ;
            if ((len = FILTER_READ(idx+1, (SV*) BUF_SV(sv), 0)) > 0) {
		BUF_NEXT(sv) = BUF_START(sv);
                if (fdebug)
                    warn ("*pipe_read(%d) Filt Rd returned %d %d [%*s]\n", 
			idx, len, BUF_SIZE(sv), BUF_SIZE(sv), BUF_START(sv)) ;
	     }
             else {
                /* eof, close write end of pipe */
                close(pipe_out) ; 
		wait(NULL) ; 
                if (fdebug)
                    warn ("*pipe_read(%d) closing pipe_out errno = %d %s\n", 
				idx, errno,
			Strerror(errno)) ;
	     }
         }
 
 	 /* write down the pipe */
         if ((w = BUF_END(sv) - BUF_NEXT(sv)) > 0)
         {       
	     errno = 0;
             if ((w = write(pipe_out, BUF_NEXT(sv), w)) > 0) {
                 BUF_NEXT(sv) += w;
                 if (fdebug)
                    warn ("*pipe_read(%d) wrote %d bytes to pipe\n", idx, w) ;
	     }
            else if (errno != VAL_EAGAIN) {
                 if (fdebug)
                    warn ("*pipe_read(%d) closing pipe_out errno = %d %s\n", 
				idx, errno, Strerror(errno)) ;
                 /* close(pipe_out) ; */
                 return 0;
	     }
             else {    /* pipe is full, sleep for a while, then continue */
                 if (fdebug)
                    warn ("*pipe_read(%d) - sleeping\n", idx ) ;
		 sleep(1);
	     }
        }
    }
}


static void
make_nonblock(f)
int  f;
{
   int RETVAL ;
   int mode = fcntl(f, F_GETFL);
 
   if (mode < 0)
        croak("fcntl(f, F_GETFL) failed, RETVAL = %d, errno = %d",
                mode, errno) ;
 
   if (!(mode & VAL_O_NONBLOCK))
       RETVAL = fcntl(f, F_SETFL, mode | VAL_O_NONBLOCK);
 
    if (RETVAL < 0)
        croak("cannot create a non-blocking pipe, RETVAL = %d, errno = %d",
                RETVAL, errno) ;
}
 
#endif


#define READER	0
#define	WRITER	1

static void
spawnCommand(fil, command, parameters, p0, p1)	
FILE * fil;
char * command ;
char * parameters[] ;
int  * p0 ;
int  * p1 ;
{
#ifdef WIN32

    int p[2], c[2];
    SV * sv ;
    int oldstdout, oldstdin;

    /* create the pipes */
    if (win32_pipe(p,512,O_TEXT|O_NOINHERIT) == -1
	|| win32_pipe(c,512,O_BINARY|O_NOINHERIT) == -1) {
	fclose( fil );
	croak("Can't get pipe for %s", command);
    }

    /* duplicate stdout and stdin */
    oldstdout = dup(fileno(stdout));
    if (oldstdout == -1) {
	fclose( fil );
	croak("Can't dup stdout for %s", command);
    }
    oldstdin  = dup(fileno(stdin));
    if (oldstdin == -1) {
	fclose( fil );
	croak("Can't dup stdin for %s", command);
    }

    /* duplicate inheritable ends as std handles for the child */
    if (dup2(p[WRITER], fileno(stdout))) {
	fclose( fil );
	croak("Can't attach pipe to stdout for %s", command);
    }
    if (dup2(c[READER], fileno(stdin))) {
	fclose( fil );
	croak("Can't attach pipe to stdin for %s", command);
    }

    /* close original inheritable ends in parent */
    close(p[WRITER]);
    close(c[READER]);

    /* spawn child process (which inherits the redirected std handles) */
    pipe_pid = spawnvp(P_NOWAIT, command, parameters);
    if (pipe_pid == -1) {
	fclose( fil );
	croak("Can't spawn %s", command);
    }

    /* restore std handles */
    if (dup2(oldstdout, fileno(stdout))) {
	fclose( fil );
	croak("Can't restore stdout for %s", command);
    }
    if (dup2(oldstdin, fileno(stdin))) {
	fclose( fil );
	croak("Can't restore stdin for %s", command);
    }

    /* close saved handles */
    close(oldstdout);
    close(oldstdin);

    *p0 = p[READER] ;
    *p1 = c[WRITER] ;

#else /* !WIN32 */

    int p[2], c[2];
    SV * sv ;
    int	pipepid;

    /* Check that the file is seekable */
    /* if (lseek(fileno(fil), ftell(fil), 0) == -1) { */
	/* croak("lseek failed: %s", Strerror(errno)) ; */
    /* }  */

    if (pipe(p) < 0 || pipe(c)) {
	fclose( fil );
	croak("Can't get pipe for %s", command);
    }

    /* make sure that the child doesn't get anything extra */
    fflush(stdout);
    fflush(stderr);

    while ((pipepid = fork()) < 0) {
	if (errno != EAGAIN) {
	    close(p[0]);
	    close(p[1]);
	    close(c[0]) ;
	    close(c[1]) ;
	    fclose( fil );
	    croak("Can't fork for %s", command);
	}
	sleep(1);
    }

    if (pipepid == 0) {
	/* The Child */

	close(p[READER]) ;
	close(c[WRITER]) ;
	if (c[READER] != 0) {
	    dup2(c[READER], 0);
	    close(c[READER]); 
	}
	if (p[WRITER] != 1) {
	    dup2(p[WRITER], 1);
	    close(p[WRITER]); 
	}

	/* Run command */
	execvp(command, parameters) ;
        croak("execvp failed for command '%s': %s", command, Strerror(errno)) ;
	fflush(stdout);
	fflush(stderr);
	_exit(0);
    }

    /* The parent */

    close(p[WRITER]) ;
    close(c[READER]) ;

    /* make the pipe non-blocking */
    make_nonblock(p[READER]) ;
    make_nonblock(c[WRITER]) ;

    *p0 = p[READER] ;
    *p1 = c[WRITER] ;
#endif
}


static I32
filter_exec(idx, buf_sv, maxlen)
    int idx;
    SV *buf_sv;
    int maxlen;
{
    I32 len;
    SV   *buffer = FILTER_DATA(idx);
    char * out_ptr = SvPVX(buffer) ;
    int	n ;
    char *	p ;
    char *	nl = "\n" ;
 
    if (fdebug)
        warn ("filter_sh(idx=%d, SvCUR(buf_sv)=%d, maxlen=%d\n", 
		idx, SvCUR(buf_sv), maxlen) ;
    while (1) {
	STRLEN n_a;

        /* If there was a partial line/block left from last time
           copy it now
        */
        if (n = SvCUR(buffer)) {
	    out_ptr  = SvPVX(buffer) + BUF_OFFSET(buffer) ;
	    if (maxlen) { 
		/* want a block */
    		if (fdebug)
		    warn("filter_sh(%d) - wants a block\n", idx) ;
                sv_catpvn(buf_sv, out_ptr, maxlen > n ? n : maxlen );
                if(n <= maxlen) {
		    BUF_OFFSET(buffer) = 0 ;
                    SET_LEN(buffer, 0) ; 
		}
                else {
		    BUF_OFFSET(buffer) += maxlen ;
                    SvCUR_set(buffer, n - maxlen) ;
                }
                return SvCUR(buf_sv);
	    }
	    else {
		/* want a line */
    		if (fdebug)
		    warn("filter_sh(%d) - wants a line\n", idx) ;
                if (p = ninstr(out_ptr, out_ptr + n - 1, nl, nl)) {
                    sv_catpvn(buf_sv, out_ptr, p - out_ptr + 1);
                    n = n - (p - out_ptr + 1);
		    BUF_OFFSET(buffer) += (p - out_ptr + 1);
                    SvCUR_set(buffer, n) ;
                    if (fdebug)
                        warn("recycle(%d) - leaving %d [%s], returning %d %d [%s]", 
				idx, n, 
				SvPVX(buffer), p - out_ptr + 1, 
				SvCUR(buf_sv), SvPVX(buf_sv)) ;
     
                    return SvCUR(buf_sv);
                }
                else /* partial buffer didn't have any newlines, so copy it all */
		    sv_catpvn(buf_sv, out_ptr, n) ;
	    }
 
        }
 

	/* the buffer has been consumed, so reset the length */
	SET_LEN(buffer, 0) ; 
        BUF_OFFSET(buffer) = 0 ;

        /* read from the sub-process */
        if ( (n=pipe_read(buffer, idx, maxlen)) <= 0) {
 
            if (fdebug)
                warn ("filter_sh(%d) - pipe_read returned %d , returning %d\n", 
			idx, n, (SvCUR(buf_sv)>0) ? SvCUR(buf_sv) : n);
 
            SvCUR_set(buffer, 0);
	    BUF_NEXT(buffer) = Nullch;	/* or perl will try to free() it */
            /* filter_del(filter_sh);  */
 
            /* If error, return the code */
            if (n < 0)
                return n ;
 
            /* return what we have so far else signal eof */
            return (SvCUR(buf_sv)>0) ? SvCUR(buf_sv) : n;
        }
 
        if (fdebug)
            warn("  filter_sh(%d): pipe_read returned %d %d: '%s'",
                idx, n, SvCUR(buffer), SvPV(buffer,n_a));
 
    }

}


MODULE = Filter::Util::Exec	PACKAGE = Filter::Util::Exec

REQUIRE:	1.924
PROTOTYPES:	ENABLE

BOOT:
    /* temporary hack to control debugging in toke.c */
    filter_add(NULL, (fdebug) ? (SV*)"1" : (SV*)"0"); 


void
filter_add(module, command, ...)
    SV *	module = NO_INIT
    char **	command = (char**) safemalloc(items * sizeof(char*)) ;
    PROTOTYPE:	$@
    CODE:
      	int i ;
      	int pipe_in, pipe_out ;
	STRLEN n_a ;
	/* SV * sv = newSVpv("", 0) ; */
	SV * sv = newSV(1) ;
 
      if (fdebug)
          warn("Filter::exec::import\n") ;
      for (i = 1 ; i < items ; ++i)
      {
          command[i-1] = SvPV(ST(i), n_a) ;
      	  if (fdebug)
	      warn("    %s\n", command[i-1]) ;
      }
      command[i-1] = NULL ;
      filter_add(filter_exec, sv);
      spawnCommand(PL_rsfp, command[0], command, &pipe_in, &pipe_out) ;
      safefree((char*)command) ;

      PIPE_IN(sv)   = pipe_in ;
      PIPE_OUT(sv)  = pipe_out ;
      /* BUF_SV(sv)    = newSVpv("", 0) ; */
      BUF_SV(sv)    = (GV*) newSV(1) ;
      (void)SvPOK_only(BUF_SV(sv)) ;
      BUF_NEXT(sv)  = NULL ;
      BUF_OFFSET(sv) = 0 ;


