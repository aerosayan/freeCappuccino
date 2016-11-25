!***********************************************************************
!
subroutine calcuvw
!
!***********************************************************************
!
  use types, only: dp
  use parameters
  use indexes
  use geometry
  use sparse_matrix
  use variables
  use gradients, only:grad
  use temperature, only: t

  implicit none
!
!***********************************************************************

!
! Local variables
!
  integer :: i, k, inp, ijp, ijn, istage
  real(dp) :: urfrs, urfms, apotime, heat
  real(dp) :: sut, svt, swt 
  real(dp) :: sup, svp, swp
  real(dp) :: off_diagonal_terms

  ! logical :: ScndOrderWallBC_Model
  integer :: ijb            ! Boundary field value indexes
  real(dp) :: cp, cb        ! Temp. for eq. coeficients
  real(dp) :: cap, can      ! Temp. for eq. coeficients
  real(dp) :: vsi           ! Interpolated dynamic viscosity
  real(dp) :: cf            ! Diffusion coefficient
  real(dp) :: nxf, nyf, nzf ! Boundary face normals
  real(dp) :: Are           ! Face area
  real(dp) :: dpb           ! distance cell center to face center at boundary
  real(dp) :: vsol          ! Diffusion coefficient (II)
  real(dp) :: fdne          ! Diffusive flux auxiliary
  ! real(dp) :: FdUi,FdVi,FdWi! Diffusive flux auxiliary
  real(dp) :: Upb, Vpb, Wpb ! Velocity difference
  real(dp) :: Utp, Vtp, Wtp
  real(dp) :: Vnp
  real(dp) :: viss

  ! ScndOrderWallBC_Model = .false.
  
  ! Velocity gradients: 
  call grad(U,dUdxi)
  call grad(V,dVdxi)
  call grad(W,dWdxi)

  ! Pressure gradient
  do istage=1,nipgrad
    ! Pressure at boundaries (for correct calculation of press. gradient)
    call bpres(p,istage)
    ! Calculate pressure gradient.
    call grad(p,dPdxi)
  end do


  ! CALCULATE SOURCE TERMS INTEGRATED OVER VOLUME
  do inp=1,numCells

    !.....for u  sp => spu; for v  sp => spv; for w  sp => sp
    !.....sum source terms
    spu(inp) = 0.0d0
    spv(inp) = 0.0d0
    sp(inp) = 0.0d0

    !=======================================================================
    ! Pressure source terms
    !=======================================================================
    su(inp) = -dPdxi(1,inp)*vol(inp)
    sv(inp) = -dPdxi(2,inp)*vol(inp)
    sw(inp) = -dPdxi(3,inp)*vol(inp)

    ! Constant mass flow forcing - used only on U velocity component
    !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    if(const_mflux) su(inp) = su(inp) + gradPcmf*vol(inp)
    !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    !=======================================================================
    ! Buoyancy source terms
    !=======================================================================
    if(lcal(ien).and.lbuoy) then
      !-----------------------------------------------------------------------
      !........[Boussinesq-ova aproximacija: ]
      !-----------------------------------------------------------------------
      heat=0.0d0
      if(boussinesq.eq.1) then
        heat = beta*densit*(t(inp)-tref)*vol(inp)
      else ! if(boussinesq.eq.0)
        heat = (densit-den(inp))*vol(inp)
      endif
      !-----------------------------------------------------------------------
      su(inp) = su(inp) - gravx*heat
      sv(inp) = sv(inp) - gravy*heat
      sw(inp) = sw(inp) - gravz*heat
    endif

    !=======================================================================
    ! Unsteady term
    !=======================================================================
    if(bdf) then
    !-----------------------------------------------------------------------
    ! Backward differentiation formula:
    ! in case that BTIME=0. --> Implicit Euler
    ! in case that BTIME=1. --> Three Level Implicit Time Integration Method or BDF2
    !-----------------------------------------------------------------------
      apotime=den(inp)*vol(inp)/timestep

      ! sut=apotime*((1+btime)*uo(inp)-0.5*btime*uoo(inp))
      ! svt=apotime*((1+btime)*vo(inp)-0.5*btime*voo(inp))
      ! swt=apotime*((1+btime)*wo(inp)-0.5*btime*woo(inp))

      sut = apotime*((1+btime)*uo(inp))
      svt = apotime*((1+btime)*vo(inp))
      swt = apotime*((1+btime)*wo(inp))
    
      if (btime > 0.5) then
        sut = sut - apotime*(0.5*btime*uoo(inp))
        svt = svt - apotime*(0.5*btime*voo(inp))
        swt = swt - apotime*(0.5*btime*woo(inp))
      endif

      su(inp) = su(inp) + sut
      sv(inp) = sv(inp) + svt
      sw(inp) = sw(inp) + swt

      spu(inp) = spu(inp) + apotime*(1+0.5*btime)
      spv(inp) = spv(inp) + apotime*(1+0.5*btime)
      sp(inp)  = sp(inp)  + apotime*(1+0.5*btime)
    !-----------------------------------------------------------------------
    endif

  end do



  !=======================================================================
  ! ADDITIONAL TERMS:
  !=======================================================================
  IF(LTURB.AND.LASM) THEN

    ! Calculate Reynols stresses explicitly
    call calcstress

    call Additional_algebraic_stress_terms
    
  END IF
      

  ! Calculate terms integrated over surfaces
  ! Only inner faces

  ! East faces
  do i = 1,numInnerFaces

    ijp = owner(i)
    ijn = neighbour(i)

    call facefluxuvw(ijp, ijn, xf(i), yf(i), zf(i), arx(i), ary(i), arz(i), flmass(i), facint(i), gds(iu), &
      cap, can, sup, svp, swp)

    ! > Off-diagonal elements:

    ! (icell,jcell) matrix element:
    k = icell_jcell_csr_value_index(i)
    a(k) = can

    ! (jcell,icell) matrix element:
    k = jcell_icell_csr_value_index(i)
    a(k) = cap

    ! > Elements on main diagonal:

    ! ! (icell,icell) main diagonal element
    ! k = diag(ijp)
    ! a(k) = a(k) - can

    ! ! (jcell,jcell) main diagonal element
    ! k = diag(ijn)
    ! a(k) = a(k) - cap

    ! > Sources: 

    su(ijp) = su(ijp) + sup
    sv(ijp) = sv(ijp) + svp
    sw(ijp) = sw(ijp) + swp

    su(ijn) = su(ijn) - sup
    sv(ijn) = sv(ijn) - svp
    sw(ijn) = sw(ijn) - swp

  end do



  ! O- and C-grid cuts (these are not boundaries!)
  ! Loop faces
  do i=1,noc
    ijp=ijl(i)
    ijn=ijr(i)

    call facefluxuvw(ijp, ijn, xfoc(i), yfoc(i), zfoc(i), xnoc(i), ynoc(i), znoc(i), fmoc(i), foc(i), gds(iu), &
      al(i), ar(i), sup, svp, swp)  

    spu(ijp) = spu(ijp) - ar(i)
    spv(ijp) = spv(ijp) - ar(i)
    sp(ijp)  = sp(ijp)  - ar(i)

    spu(ijn) = spu(ijn) - al(i)
    spv(ijn) = spv(ijn) - al(i)
    sp(ijn)  = sp(ijn)  - al(i)

  end do


      
  ! Implement boundary conditions

  ! Inlet

  ! Loop Inlet faces
  do i=1,ninl
    ijp = owner(iInletFacesStart+i)
    ijb = iInletStart+i

    dUdxi(:,ijb) = dUdxi(:,ijp) ! Adjust gradient at inlet to be equal to that in cell center (constant gradient bc)
    dVdxi(:,ijb) = dVdxi(:,ijp)
    dWdxi(:,ijb) = dWdxi(:,ijp)

    CALL faceFluxUVW(ijp, ijb, xfi(i), yfi(i), zfi(i), xni(i), yni(i), zni(i), fmi(i), one, zero, &
     cp, cb, sup, svp, swp)

    spu(ijp) = spu(ijp) - cb
    spv(ijp) = spv(ijp) - cb
    sp(ijp)  = sp(ijp)  - cb

    su(ijp) = su(ijp) - cb*u(ijb)
    sv(ijp) = sv(ijp) - cb*v(ijb)
    sw(ijp) = sw(ijp) - cb*w(ijb)
  
  end do

  ! Outlet

  ! Loop Outlet faces
  do i=1,nout
    ijp = owner(iOutletFacesStart+i)
    ijb = iOutletStart+i

    dUdxi(:,ijb) = dUdxi(:,ijp) ! Adjust gradient at inlet to be equal to that in cell center (constant gradient bc)
    dVdxi(:,ijb) = dVdxi(:,ijp)
    dWdxi(:,ijb) = dWdxi(:,ijp)

    CALL faceFluxUVW(ijp, ijb, xfo(i), yfo(i), zfo(i), xno(i), yno(i), zno(i), fmo(i), one, zero, &
     cp, cb, sup, svp, swp)  

    spu(ijp) = spu(ijp) - cb
    spv(ijp) = spv(ijp) - cb
    sp(ijp)  = sp(ijp)  - cb

    su(ijp) = su(ijp) - cb*u(ijb)
    sv(ijp) = sv(ijp) - cb*v(ijb)
    sw(ijp) = sw(ijp) - cb*w(ijb)

  end do

  ! Symmetry
  do i=1,nsym
    ijp = owner(iSymmetryFacesStart+i)
    ijb = iSymmetryStart+i

    ! Diffusion coef.
    Vsi = Vis(ijb)
    cf = Vsi*Srds(i) ! cf v.s. vsol -> cf is calculated using normal distance in srds!

    ! Face area 
    Are = sqrt(xns(i)**2+yns(i)**2+zns(i)**2)

    ! Face normals
    nxf = xns(i)/(Are+Small)
    nyf = yns(i)/(Are+Small)
    nzf = zns(i)/(Are+Small)

    Dpb = sqrt( (Xc(ijp)-Xfs(i))**2 + (Yc(ijp)-Yfs(i))**2 + (Zc(ijp)-Zfs(i))**2 )
    Vsol = Vsi*Are/(Dpb+Small)

    Upb = U(ijp)-U(ijb)
    Vpb = V(ijp)-V(ijb)
    Wpb = W(ijp)-W(ijb)

    FdNe = 2.*cf*( Upb*nxf + Vpb*nyf + Wpb*nzf )

    Spu(ijp) = Spu(ijp) + Vsol
    Spv(ijp) = Spv(ijp) + Vsol
    Sp(ijp)  = Sp(ijp)  + Vsol

    Su(ijp) = Su(ijp)+Vsol*U(ijp)-FdNe*nxf
    Sv(ijp) = Sv(ijp)+Vsol*V(ijp)-FdNe*nyf
    Sw(ijp) = Sw(ijp)+Vsol*W(ijp)-FdNe*nzf

  end do

  do i=1,nwal
    ijp = owner(iWallFacesStart+i)
    ijb = iWallStart+i

    viss = viscos ! viskoznost interolirana na boundary face
    if(lturb.and.ypl(i).gt.ctrans) viss=visw(i)
    cf=viss*Srdw(i) ! cf v.s. vsol -> cf is callculated using normal distance in srdw!

    ! Face area 
    Are=sqrt(xnw(i)**2+ynw(i)**2+znw(i)**2)

    ! Face normals
    nxf = xnw(i)/(Are+Small)
    nyf = ynw(i)/(Are+Small)
    nzf = znw(i)/(Are+Small)

    ! distanca od ijp do ijb
    Dpb = sqrt( (Xc(ijp)-Xfw(i))**2 + (Yc(ijp)-Yfw(i))**2 + (Zc(ijp)-Zfw(i))**2 ) 
    ! Diffusion coef. 
    Vsol = Viss*Are/(Dpb+Small)

    ! Razlika brzina u dve tacke po komponentama
    Upb = U(ijp)-U(ijb)
    Vpb = V(ijp)-V(ijb)
    Wpb = W(ijp)-W(ijb)

    ! Projektujes taj vektor razlike brzina na normalu za brzinu duz normale
    Vnp = Upb*nxf+Vpb*nyf+Wpb*nzf

    ! Tangencijalna komponente brzina.
    Utp = Upb-Vnp*nxf
    Vtp = Vpb-Vnp*nyf
    Wtp = Wpb-Vnp*nzf

    ! if (ScndOrderWallBC_Model) then

    !   ! Eksplicitna difuzija
    !   FdUi=viss*((dUdxi(1,ijp)+dUdxi(1,ijp))*nxf+(dUdxi(2,ijp)+dVdxi(1,ijp))*nyf+(dUdxi(3,ijp)+dWdxi(1,ijp))*nzf)
    !   FdVi=viss*((dVdxi(1,ijp)+dUdxi(2,ijp))*nxf+(dVdxi(2,ijp)+dVdxi(2,ijp))*nyf+(dVdxi(3,ijp)+dWdxi(2,ijp))*nzf)
    !   FdWi=viss*((dWdxi(1,ijp)+dUdxi(3,ijp))*nxf+(dWdxi(2,ijp)+dVdxi(3,ijp))*nyf+(dWdxi(3,ijp)+dWdxi(3,ijp))*nzf)
    !   ! Projektujes eksplicitnu difuziju na nomalu
    !   FdNe = FdUi*nxf + FdVi*nyf + FdWi*nzf
    !   ! oduzmes od eksplicitne difuzije onu komponentu duz normale
    !   FdUi = FdUi-FdNe*nxf
    !   FdVi = FdVi-FdNe*nyf
    !   FdWi = FdWi-FdNe*nzf

    !   Ap(ijp) = Ap(ijp)+Vsol

    !   Su(ijp) = Su(ijp)+Vsol*U(ijp)-(2*cf*Utp+FdUi*Are)
    !   Sv(ijp) = Sv(ijp)+Vsol*V(ijp)-(2*cf*Vtp+FdVi*Are)
    !   Sw(ijp) = Sw(ijp)+Vsol*W(ijp)-(2*cf*Wtp+FdWi*Are)

    ! else

      Spu(ijp) = Spu(ijp) + Vsol
      Spv(ijp) = Spv(ijp) + Vsol
      Sp(ijp)  = Sp(ijp)  + Vsol

      Su(ijp) = Su(ijp) + Vsol*U(ijp) - cf*Utp
      Sv(ijp) = Sv(ijp) + Vsol*V(ijp) - cf*Vtp
      Sw(ijp) = Sw(ijp) + Vsol*W(ijp) - cf*Wtp

    ! endif

  enddo




  ! Modify coefficients for Crank-Nicolson
  if (cn) then
    a(:) = 0.5_dp*a(:) ! Doesn't affect the main diagonal because it's still zero.
  endif


  !
  !.....Assemble and solve system for U component of velocity
  !

  ! Crank-Nicolson time stepping source terms
  if (cn) then

    do i = 1,numInnerFaces
        ijp = owner(i)
        ijn = neighbour(i)

        k = icell_jcell_csr_value_index(i)
        su(ijp) = su(ijp) - a(k)*uo(ijn)

        k = jcell_icell_csr_value_index(i)
        su(ijn) = su(ijn) - a(k)*uo(ijp)
    enddo

    do ijp=1,numCells
        apotime = den(ijp)*vol(ijp)/timestep
        off_diagonal_terms = sum( a(ioffset(ijp) : ioffset(ijp+1)-1) ) !- a(diag(ijp))
        su(ijp) = su(ijp) + (apotime + off_diagonal_terms)*uo(ijp)
        spu(ijp) = spu(ijp) + apotime
    enddo

  endif

  urfrs=urfr(iu)
  urfms=urfm(iu)

  do inp = 1,numCells

    ! Main diagonal term assembly:
    ! Sum all coefs in a row of a sparse matrix, but since we also included diagonal element 
    ! we substract it from the sum, to eliminate it from the sum.
    ! We could also write sum( a(ioffset(inp)) : a(ioffset(inp+1)-1) ) because all diagonal terms are zero.
    off_diagonal_terms  = sum( a(ioffset(inp) : ioffset(inp+1)-1) ) !- a(diag(inp)) 
    a(diag(inp)) = spu(inp) - off_diagonal_terms

    ! Underelaxation:
    a(diag(inp)) = a(diag(inp))*urfrs
    su(inp) = su(inp) + urfms*a(diag(inp))*u(inp)

    apu(inp) = 1./(a(diag(inp))+small) ! SIMPLE,PISO

  enddo

  ! Solve fvm equations
  call bicgstab(u,iu) 





  !
  !.....Assemble and solve system for V component of velocity
  !

  ! Crank-Nicolson time stepping source terms
  if(cn) then

    do i = 1,numInnerFaces
        ijp = owner(i)
        ijn = neighbour(i)

        k = icell_jcell_csr_value_index(i)
        sv(ijp) = su(ijp) - a(k)*vo(ijn)

        k = jcell_icell_csr_value_index(i)
        sv(ijn) = su(ijn) - a(k)*vo(ijp)
    enddo

    do ijp=1,numCells
        apotime=den(ijp)*vol(ijp)/timestep
        off_diagonal_terms = sum( a(ioffset(ijp) : ioffset(ijp+1)-1) ) !- a(diag(ijp))
        sv(ijp) = sv(ijp) + (apotime + off_diagonal_terms)*vo(ijp)
        spv(ijp) = spv(ijp)+apotime
    enddo

  endif

  urfrs=urfr(iv)
  urfms=urfm(iv)
  
  do inp = 1,numCells

    ! Main diagonal term assembly:
    off_diagonal_terms  = sum( a(ioffset(inp) : ioffset(inp+1)-1) ) !- a(diag(inp)) 
    a(diag(inp)) = spu(inp) - off_diagonal_terms

    ! Underelaxation:
    a(diag(inp)) = a(diag(inp))*urfrs
    sv(inp) = sv(inp) + urfms*a(diag(inp))*v(inp)

    apv(inp) = 1./(a(diag(inp))+small) ! SIMPLE,PISO
  enddo

  ! Solve fvm equations
  call bicgstab(v,iv)




 
  !
  !.....Assemble and solve system for V component of velocity
  !

  ! Crank-Nicolson time stepping source terms
  if(cn) then

    do i = 1,numInnerFaces
        ijp = owner(i)
        ijn = neighbour(i)

        k = icell_jcell_csr_value_index(i)
        sw(ijp) = sw(ijp) - a(k)*wo(ijn)

        k = jcell_icell_csr_value_index(i)
        sw(ijn) = sw(ijn) - a(k)*wo(ijp)
    enddo

    do ijp=1,numCells
        apotime = den(ijp)*vol(ijp)/timestep
        off_diagonal_terms = sum( a(ioffset(ijp) : ioffset(ijp+1)-1) ) !- a(diag(ijp))
        sw(ijp) = sw(ijp) + (apotime + off_diagonal_terms)*wo(ijp)
        sp(ijp) = sp(ijp) + apotime
    enddo

  endif 

  urfrs=urfr(iw)
  urfms=urfm(iw)
    
  do inp = 1,numCells

    ! Main diagonal term assembly:
    off_diagonal_terms  = sum( a(ioffset(inp) : ioffset(inp+1)-1) ) !- a(diag(inp)) 
    a(diag(inp)) = sp(inp) - off_diagonal_terms

    ! Underelaxation:
    a(diag(inp)) = a(diag(inp))*urfrs
    sw(inp) = sw(inp) + urfms*a(diag(inp))*w(inp)

    apw(inp) = 1./(a(diag(inp))+small) ! SIMPLE,PISO

  enddo

  ! Solve fvm equations
  call bicgstab(w,iw)


end subroutine