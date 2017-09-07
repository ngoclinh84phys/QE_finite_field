#!/bin/sh
#############################################################################
# Author:                                                                   #
# ------                                                                    #
# Anton Kokalj                                   Email: Tone.Kokalj@ijs.si  #
#                                                                           #
# Copyright (c) 2004 by Anton Kokalj                                        #
#############################################################################

#------------------------------------------------------------------------
# This file is distributed under the terms of the
# GNU General Public License. See the file `License'
# in the root directory of the present distribution,
# or http://www.gnu.org/copyleft/gpl.txt .
#------------------------------------------------------------------------
# make sure there is no locale setting creating unneeded differences.
LC_ALL=C
export LC_ALL

#
# Purpose: PWscf(v2.0 or latter)-output--to--XSF conversion
# Usage:   pwo2xsf [options] pw-output-file
#
# Last major rewrite by Tone Kokalj on Mon Feb  9 12:48:10 CET 2004
#                       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

cat > pwo2xsfUsage.$$ <<EOF

 Usage: pwo2xsf.sh [options] [pw-output-file]

 Options are:

               pwo2xsf.sh --inicoor|-ic [pw-output-file]
                             Extract the initial (i.e. input) 
                             ionic coordinates.

               pwo2xsf.sh --latestcoor|-lc [pw-output-file]
                             Extract latest estimation of ionic 
                             coordinates from pw-output file. The coordinates 
                             can be either taken from "Search of equilibrium 
                             positions" record or from "Final estimate of 
                             positions" record.

               pwo2xsf.sh --optcoor|-oc [pw-output-file]
			     Similar to "--latestcoor", but extract just the 
			     optimized coordinates.

	       pwo2xsf.sh --animxsf|-a [pw-output-file1] ...
			     Similar to "--latestcoor", but extract the
			     coordinates from all ionic steps and make
			     an AXSF file for animation.
EOF


# ------------------------------------------------------------------------
# Utility functions
# ------------------------------------------------------------------------
CleanTmpFiles() {
    if test -f pwo2xsfUsage.$$ ; then rm -f pwo2xsfUsage.$$; fi
    if test -f xsf.$$ ; then rm -f xsf.$$; fi
    if test -f pw.$$ ; then rm -f pw.$$; fi
}
pwoExit() {
    # Usage: $0 exit_status
    CleanTmpFiles
    exit $1
}
pwoUsage() {
    if test $1 ; then
	echo "
Usage: $2
"
	pwoExit 1
    fi
}
pwoGetVersion() {
    grep 'Program PWSCF' $1 | tail -1 | awk '
      {  ver=$3; n=split(ver,v,"."); 
         ii=0; for(i=1; i<=n; i++) if ( v[i] ~ /[0-9]+/ ) vv[ii++]=v[i];  
         if (ii>2) printf "%d.%d%d\n", vv[0],vv[1],vv[2];
         else printf "%d.%d\n", vv[0], vv[1];
      }'
}
pwoCheckPWSCFVersion() {
    #
    # Usage: $0 option file
    #
    # Purpose: if PWSCF version < 1.3 execute the old pwo2xsf_old.sh
    #          script and exit
    version=`pwoGetVersion $input`
    result=`echo "$version < 1.3"|bc -l`
    if test $result -eq 1 ; then
	if test -f $scriptdir/pwo2xsf_old.sh ; then
    	   # execute pwo2xsf_old.sh
	    $scriptdir/pwo2xsf_old.sh $1 $2
	    pwoExit $?
	else
	    echo "ERROR: PWscf output generated by version < 1.3 !!!"
	    pwoExit 1
	fi
    fi
}


# ------------------------------------------------------------------------
# Function: pwoOptCoor
# Extract:  OPTIMIZED or LATEST coordinates
# Perform:  read PW-output file and print the XSF file according to
#           specified flags
# ------------------------------------------------------------------------
pwoOptCoor() {
    #set -x
    pwoUsage "$# -lt 1" \
	"$0 --latestcoor|-lc [pw-output-file]   or   $0 --optcoor|-oc [pw-output-file]"
    
    option=$1
    case $1 in
	--latestcoor|-lc) type=LATEST;    shift;;
	--optcoor|-oc)    type=OPTIMIZED; shift;;
    esac
    
    if test $# -eq 0 ; then
	input=pw.$$
	cat - >> $input
    else
	input=$1
    fi
    
    pwoCheckPWSCFVersion $option $input

    if test $type = "OPTIMIZED" ; then
	# Check for the presence of CELL_PARAMETERS record
	# and/or:
	# Check also for the PWSCF-v.1.3.0 which uses the
	# "Final estimate of positions" record
	if test \( "`grep CELL_PARAMETERS $input`" = "" \) -a \( "`grep 'Final estimate of positions' $input`" = "" \) ; then
	    echo "ERROR: OPTIMIZED coordinates does not exists"
	    pwoExit 1
	fi
    fi

    cat "$input" | awk -v t=$type '
function CheckAtoms() {
  if (nat < 1) {
    print "ERROR: no atoms found";
    error_status=1;
    exit 1;
  }
}

function CrysToCartCoor(i,v,a,b,c) {
  # Crystal --> Cartesian (ANGSTROM units) conversion
  x[i] = v[0,0]*a + v[1,0]*b + v[2,0]*c;
  y[i] = v[0,1]*a + v[1,1]*b + v[2,1]*c;
  z[i] = v[0,2]*a + v[1,2]*b + v[2,2]*c;
}

function make_error(message,status) {
  printf "ERROR: %s\n", message;
  error_status=status;
  exit status;
}


BEGIN { 
  nat=0; 
  opt_coor_found=0; 
  error_status=0;
  bohr=0.529177
}


/celldm\(1\)=/    { a0=$2*bohr; scale=a0; l_scale=a0; }
/number of atoms/ { nat=$NF; }


/crystal axes:/   {
  # read the lattice-vectors
  for (i=0; i<3; i++) {
    getline;
    for (j=4; j<7; j++) v[i,j-4] = $j * a0;      
  }
}


$1 == "CELL_PARAMETERS" {
  # read the lattice-vectors (type=OPTIMIZED)
  opt_coor_found=1;
  ff=l_scale;
  if ( $2 ~ /alat/ )          ff=a0;
  else if ( $2 ~ /angstrom/ ) ff=1.0;
  else if ( $2 ~ /bohr/ )     ff=bohr;
  CheckAtoms();
  for (i=0; i<3; i++) {
    getline;
    if (NF != 3) make_error("error reading CELL_PARAMETERS records",1);
    for (j=1; j<4; j++) {
      v[i,j-1] = ff * $j;       
    }
  }
}    


$1 == "ATOMIC_POSITIONS" {
  crystal_coor=0;
  if ( $2 ~ /alat/ )          scale=a0;
  else if ( $2 ~ /angstrom/ ) scale=1.0;
  else if ( $2 ~ /bohr/ )     scale=bohr;
  else if ( $2 ~ /crystal/ ) {
    scale=1.0;
    crystal_coor=1;
  }
  CheckAtoms();
  for(i=0; i<nat; i++) {
    getline;
    if (NF != 4) make_error("error reading ATOMIC_POSITIONS records",1);
    atom[i]=$1; 
    a=scale*$2;
    b=scale*$3;
    c=scale*$4; 
    if (crystal_coor) {
      CrysToCartCoor(i,v,a,b,c); 
    } else {
      x[i]=a; y[i]=b; z[i]=c; 
    }
  }
}


/Forces acting on atoms/ { 
  # read forces
  getline;
  for(i=0; i<nat; i++) {
    getline;
    if (NF != 9) make_error("error reading Forces records",1);
    fx[i]=$7; fy[i]=$8; fz[i]=$9;
  }
}


/Final estimate of positions/ {
  # the PWscf v.1.3.0 has still this record
  opt_coor_found=1;
}


END {
  if (error_status==0) {
    if (t=="OPTIMIZED" && !opt_coor_found) {
      print "ERROR: no optimized coordinates";
      exit 1;
    }      
    printf "CRYSTAL\n";
    printf "PRIMVEC\n";
    printf "  %15.10f %15.10f %15.10f\n", v[0,0], v[0,1], v[0,2];
    printf "  %15.10f %15.10f %15.10f\n", v[1,0], v[1,1], v[1,2];
    printf "  %15.10f %15.10f %15.10f\n", v[2,0], v[2,1], v[2,2];
    printf "PRIMCOORD\n %d 1\n", nat;

    for(i=0; i<nat; i++)
      printf "%  3s   % 15.10f  % 15.10f  % 15.10f   % 15.10f  % 15.10f  % 15.10f\n", atom[i], x[i], y[i], z[i], fx[i], fy[i], fz[i];
  }
}'
}


# ------------------------------------------------------------------------
# Function: pwoAnimCoor
# Extract:  INITIAL or ALL coordinates
# Perform:  read PW-output file and print the XSF file according to
#           specified flags
# ------------------------------------------------------------------------

pwoAnimCoor() {
    #set -x
    pwoUsage "$# -lt 1" "$0 --animcoor|-ac|--animxsf|-a [pw-output-file1] or   $0 --inicoor|-ic [pw-output-file]"
    
    option=$1
    only_init=0
    case $1 in
	--inicoor|-ic) only_init=1; shift;;
	--animcoor|-ac|--animxsf|-a) only_init=0; shift;;
    esac

    if test $# -eq 0 ; then
	input=pw.$$
	cat - >> $input
    else
	input=$1
    fi

    pwoCheckPWSCFVersion $option $input

    ncoor=`egrep "ATOMIC_POSITIONS" $input | wc | awk '{print $1}'`
    ncoor=`expr $ncoor + 1`; # add another step for initial coordinates
    nvec=`egrep "CELL_PARAMETERS" $input | wc | awk '{print $1}'`
    
    cat "$input" | awk \
	-v ncoor=$ncoor \
	-v nvec=$nvec \
	-v onlyinit=$only_init '
function PrintPrimVec(is_vc,ith,vec) {
  if (!is_vc) printf "PRIMVEC\n";
  else        printf "PRIMVEC %d\n",ith;
  printf "  %15.10f %15.10f %15.10f\n", v[0,0], v[0,1], v[0,2];
  printf "  %15.10f %15.10f %15.10f\n", v[1,0], v[1,1], v[1,2];
  printf "  %15.10f %15.10f %15.10f\n", v[2,0], v[2,1], v[2,2];  
}

function PrintPrimCoor(onlyinit,istep, nat, atom, x, y, z, fx, fy, fz) {
  if (onlyinit) {
    print " PRIMCOORD";
  } else {
    print " PRIMCOORD", istep;
  }
  print nat, 1;
  
  for(i=0; i<nat; i++) {
    printf "  %3s    % 15.10f  % 15.10f  % 15.10f    % 15.10f  % 15.10f  % 15.10f\n", atom[i], x[i], y[i], z[i], fx[i], fy[i], fz[i];
  }
}

function GetInitCoor(nat, scale, atom, x, y, z) {
  for(i=0; i<nat; i++) {
    atom[i]=$2;
    split($0,rec,"("); split(rec[3],coor," ");
    x[i]= scale*coor[1]; y[i]=scale*coor[2]; z[i]=scale*coor[3];
    getline;
  }
}

function CrysToCartCoor(i,v,a,b,c) {
  # Crystal --> Cartesian (ANGSTROM units) conversion
  x[i] = v[0,0]*a + v[1,0]*b + v[2,0]*c;
  y[i] = v[0,1]*a + v[1,1]*b + v[2,1]*c;
  z[i] = v[0,2]*a + v[1,2]*b + v[2,2]*c;
}

function make_error(message,status) {
  printf "ERROR: %s\n", message;
  error_status=status;
  exit status;
}


BEGIN {
  bohr=0.529177;
  istep=1;
  error_status=0;
  if (nvec>1 || (nvec==1 && ncoor==2)) {
    is_vc=1; # variable-cell
  } else {
    is_vc=0;
  }
}


/celldm\(1\)=/    { a0=$2*bohr; scale=a0; l_scale=a0; }
/number of atoms/ { nat=$NF; }


/crystal axes:/   {
  # read the lattice-vectors
  for (i=0; i<3; i++) {
    getline;
    for (j=4; j<7; j++) v[i,j-4] = $j * a0;      
  }
  if (istep==1) {
    printf "CRYSTAL\n";
    PrintPrimVec(is_vc,istep,v);
  }
}


/Cartesian axes/  { 
  # read INITIAL coordinates
  getline; getline; getline;
  if (istep == 1) GetInitCoor(nat, a0, atom, x, y, z);
}


$1 == "CELL_PARAMETERS" {
  # read the lattice-vectors (type=LATEST and OPTIMIZED)
  ff=l_scale;
  if      ( $2 ~ /alat/ )     ff=a0;
  else if ( $2 ~ /angstrom/ ) ff=1.0;
  else if ( $2 ~ /bohr/ )     ff=bohr;
  for (i=0; i<3; i++) {
    getline;
    if (NF != 3) make_error("error reading CELL_PARAMETERS records",1);
    for (j=1; j<4; j++) {
      v[i,j-1] = ff * $j;       
    }
  }
  if (is_vc) PrintPrimVec(is_vc,istep,v);
}  


$1 == "ATOMIC_POSITIONS" {
  # read atomic positions
  crystal_coor=0;
  if      ( $2 ~ /alat/ )     scale=a0;
  else if ( $2 ~ /angstrom/ ) scale=1.0;
  else if ( $2 ~ /bohr/ )     scale=bohr;
  else if ( $2 ~ /crystal/ ) {
    scale=1.0;
    crystal_coor=1;
  }
  for(i=0; i<nat; i++) {
    getline;
    if (NF != 4) make_error("error reading ATOMIC_POSITIONS records",1);
    atom[i]=$1; 
    a=scale*$2;
    b=scale*$3;
    c=scale*$4; 
    if (crystal_coor) {
      CrysToCartCoor(i,v,a,b,c); 
    } else {
      x[i]=a; y[i]=b; z[i]=c; 
    }
  }
}


/Forces acting on atoms/ { 
  # read forces
  getline;
  for(i=0; i<nat; i++) {
    getline;
    if (NF != 9) make_error("error reading Forces records",1);
    fx[i]=$7; fy[i]=$8; fz[i]=$9;
  }
  if (onlyinit) exit 0;
  else PrintPrimCoor(onlyinit,istep, nat, atom, x, y, z, fx, fy, fz); 
  istep++;
}


END {
  if (error_status == 0 && onlyinit == 1) {
    PrintPrimCoor(onlyinit,istep, nat, atom, x, y, z, fx, fy, fz);
  }
}
' > xsf.$$

    if test $only_init -eq 0 ; then
    # Assign the number of ANIMSTEPS here. The reason is that the
    # output file (queue runs) is the result of several job runs, then
    # some of them might be terminated on the "wrong" place, and the
    # initial ANIMSTEPS might be wrong. The most secure way is to extract the 
    # sequential digit from the last "PRIMCOORD id" record.
	#set -x
	nsteps=`grep PRIMCOORD xsf.$$ | wc | awk '{print $1}'`    
	echo "ANIMSTEPS $nsteps" 
    fi
    cat xsf.$$
}


#######################################################################
####                              MAIN                              ###
#######################################################################

scriptdir=$XCRYSDEN_TOPDIR/scripts; # take advantage of XCRYSDEN if it exists

AWK=`type awk`
if test "$AWK" = ""; then 
    echo "ERROR: awk program not found"
    pwoExit 1
fi


if [ $# -eq 0 ]; then
    cat pwo2xsfUsage.$$
    pwoExit 1
fi

case $1 in
    --inicoor|-ic)           pwoAnimCoor $@;;
    --latestcoor|-lc)        pwoOptCoor $@;;
    --optcoor|-oc)           pwoOptCoor $@;;
    --animcoor|-ac|--animxsf|-a) pwoAnimCoor $@;;    
    *) cat pwo2xsfUsage.$$; pwoExit 1;;
esac

pwoExit 0
