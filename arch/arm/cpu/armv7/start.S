/*
 * armboot - Startup Code for OMAP3530/ARM Cortex CPU-core
 *
 * Copyright (c) 2004	Texas Instruments <r-woodruff2@ti.com>
 *
 * Copyright (c) 2001	Marius Gröger <mag@sysgo.de>
 * Copyright (c) 2002	Alex Züpke <azu@sysgo.de>
 * Copyright (c) 2002	Gary Jennejohn <garyj@denx.de>
 * Copyright (c) 2003	Richard Woodruff <r-woodruff2@ti.com>
 * Copyright (c) 2003	Kshitij <kshitij@ti.com>
 * Copyright (c) 2006-2008 Syed Mohammed Khasim <x0khasim@ti.com>
 *
 * SPDX-License-Identifier:	GPL-2.0+
 */

#include <asm-offsets.h>
#include <config.h>
#include <asm/system.h>
#include <linux/linkage.h>

/*************************************************************************
 *
 * Startup Code (reset vector)
 *
 * Do important init only if we don't start from memory!
 * Setup memory and board specific bits prior to relocation.
 * Relocate armboot to ram. Setup stack.
 *
 *************************************************************************/

	.globl	reset
	.globl	save_boot_params_ret

reset:
	/* Allow the board to save important registers */
	b	save_boot_params
save_boot_params_ret:
        /*
         * disable interrupts (FIQ and IRQ), also set the cpu to SVC32 mode,
         * except if in HYP mode already
         */
        //mrs = move to register from special register 
        //The Current Program Status Register (CPSR)
        //CPSR bit 0 to 4 (0x1f) contain processor mode bits
        //ARM Modes: USR FIQ IRQ Supervisor Monitor Abort Hypervisor Undefine Supervisor
        // r0 = cpsr;
        mrs     r0, cpsr
        // r1 = r0 & 0x1f;
        and     r1, r0, #0x1f           @ mask mode bits
        // teq = test equivalance
        // if ( r1 != 0x1a ) { 0x1a = Hypervisor Mode
        teq     r1, #0x1a               @ test for HYP mode
	//r0 = r0 & ~0x1f; clear mode bits bic = bitwise bit clear
        bicne   r0, r0, #0x1f           @ clear all mode bits
 	// r0 |= 0x13  set supervisor mode
       orrne   r0, r0, #0x13           @ set SVC mode
	// }
	// r0 |= 0xc0; disable FIQ and IRQ interrupts
        orr     r0, r0, #0xc0           @ disable FIQ and IRQ
        // cpsr = r0;
	msr     cpsr,r0
/*
 * Setup vector:
 * (OMAP4 spl TEXT_BASE is not 32 byte aligned.
 * Continue to use ROM code vector only in OMAP4 spl)
 */
#if !(defined(CONFIG_OMAP44XX) && defined(CONFIG_SPL_BUILD))
	/* Set V=0 in CP15 SCTLR register - for VBAR to point to vector */
	/* The system control coprocessor, CP15, controls and provides status information
	   for the functions implemented in the processor. The main functions of the system
	   control coprocessor are:
	   * overall system control and configuration
	   * MMU configuration and management
	   * cache configuration and management
	   * system performance monitoring
	   See Chapter 4: System Control (CortexTM-A9 Revision: r2p2 Technical Reference Manual)
	   SCTLR: System Control Register
	   MRC p15, 0, <Rt>, c1, c0, 0 ; Read SCTLR into Rt
	   MCR p15, 0, <Rt>, c1, c0, 0 ; Write Rt to SCTLR
	*/
	// r0 = SCTLR register
	mrc	p15, 0, r0, c1, c0, 0	@ Read CP15 SCTLR Register
	/* Vectors bit is bit # 13 of the SCTRL register. 
	   This bit selects the base address of the exception vectors.
	   The possible values of this bit are:
	   0 Low exception vectors, base address 0x00000000.
	   1 High exception vectors (Hivecs), base address 0xFFFF0000.
	*/
	// r0 &= ~(1<<13);
    // So here we are setting the normal (low) exception vectors.
	bic	r0, #CR_V		@ V = 0
	// SCTLR = r0;
	mcr	p15, 0, r0, c1, c0, 0	@ Write CP15 SCTLR Register
	/* VBAR, Vector Base Address Register:
       "See ARM Architecture Reference Manual
	   ARMv7-A and ARMv7-R edition"
	   also section 'Exception vectors and the exception base address'
	   When high exception vectors are not selected, the VBAR holds the
	   exception base address.
	   MRC p15, 0, <Rt>, c12, c0, 0 ; Read VBAR into Rt
	   MCR p15, 0, <Rt>, c12, c0, 0 ; Write Rt to VBAR
	*/
	/* Set vector address in CP15 VBAR register */
	//r0 = address of routine _start (See arch/arm/lib/vectors.S)
	ldr	r0, =_start
	//VBAR = r0
	mcr	p15, 0, r0, c12, c0, 0	@Set VBAR
#endif

	/* the mask ROM code should have PLL and others stable */
#ifndef CONFIG_SKIP_LOWLEVEL_INIT
	bl	cpu_init_cp15
	bl	cpu_init_crit
#endif

	bl	_main

/*------------------------------------------------------------------------------*/

ENTRY(c_runtime_cpu_setup)
/*
 * If I-cache is enabled invalidate it
 */
#ifndef CONFIG_SYS_ICACHE_OFF
	mcr	p15, 0, r0, c7, c5, 0	@ invalidate icache
	mcr     p15, 0, r0, c7, c10, 4	@ DSB
	mcr     p15, 0, r0, c7, c5, 4	@ ISB
#endif

	bx	lr

ENDPROC(c_runtime_cpu_setup)

/*************************************************************************
 *
 * void save_boot_params(u32 r0, u32 r1, u32 r2, u32 r3)
 *	__attribute__((weak));
 *
 * Stack pointer is not yet initialized at this moment
 * Don't save anything to stack even if compiled with -O0
 *
 *************************************************************************/
ENTRY(save_boot_params)
	b	save_boot_params_ret		@ back to my caller
ENDPROC(save_boot_params)
	.weak	save_boot_params

/*************************************************************************
 *
 * cpu_init_cp15
 *
 * Setup CP15 registers (cache, MMU, TLBs). The I-cache is turned on unless
 * CONFIG_SYS_ICACHE_OFF is defined.
 *
 *************************************************************************/
ENTRY(cpu_init_cp15)

	//See Chapter 4: System Control (CortexTM-A9 Revision: r2p2 Technical Reference Manual)
	/*
	 * Invalidate L1 I/D
	 */
	mov	r0, #0			@ set up for MCR
	// see ARMV7 ref manual
	// Table B3-50 TLB maintenance operations
	// Invalidate entire unified TLB
	mcr	p15, 0, r0, c8, c7, 0	@ invalidate TLBs
	// Table B3-49 Cache and branch predictor maintenance operations
	// Instruction cache invalidate all
	mcr	p15, 0, r0, c7, c5, 0	@ invalidate icache
	// Branch predictor invalidate all
	mcr	p15, 0, r0, c7, c5, 6	@ invalidate BP array
	// Data Synchronization Barrier (DSB)
	mcr     p15, 0, r0, c7, c10, 4	@ DSB
	/* Instruction Synchronization Barrier flushes the pipeline in
	   the processor, so that all instructions following the ISB
	   are fetched from cache or memory, after the instruction has
	   been completed. It ensures that the effects of context changing
	   operations executed before the ISB instruction are visible to the
	   instructions fetched after the ISB.
	*/
	mcr     p15, 0, r0, c7, c5, 4	@ ISB

	/*
	 * disable MMU stuff and caches
	 */
	// r0 = SCTLR Register
	mrc	p15, 0, r0, c1, c0, 0
	// r0 |= ~0x2007;
	// Vector table at low
	bic	r0, r0, #0x00002000	@ clear bits 13 (--V-)
	//Disable MMU
	// Disable alignment fault checking
	// Disable caches
	bic	r0, r0, #0x00000007	@ clear bits 2:0 (-CAM)
	// r0 |= 0x802;
	// enable alignment fault checking
	orr	r0, r0, #0x00000002	@ set bit 1 (--A-) Align
	//  Program flow prediction enable
	orr	r0, r0, #0x00000800	@ set bit 11 (Z---) BTB
#ifdef CONFIG_SYS_ICACHE_OFF
	bic	r0, r0, #0x00001000	@ clear bit 12 (I) I-cache
#else
	//r0 |= 0x1000; Enable Instruction Cache
	orr	r0, r0, #0x00001000	@ set bit 12 (I) I-cache
#endif
	// SCTLR = r0;
	mcr	p15, 0, r0, c1, c0, 0

	// Erratas defined in ./include/configs/mx6_common.h for imx6
	// Read ARM® CortexTM-A9 processors r2 releases Software Developers Errata Notice

#ifdef CONFIG_ARM_ERRATA_716044
	mrc	p15, 0, r0, c1, c0, 0	@ read system control register
	orr	r0, r0, #1 << 11	@ set bit #11
	mcr	p15, 0, r0, c1, c0, 0	@ write system control register
#endif

#if (defined(CONFIG_ARM_ERRATA_742230) || defined(CONFIG_ARM_ERRATA_794072))
	/* Errata: (794072) A short loop including a DMB instruction might cause a denial
	   of service on another processor which executes a CP15 broadcast operation
	   Workaround:
	   This erratum can be worked round by setting bit[4] of the undocumented Diagnostic
	   Control Register to 1. This register is encoded as CP15 c15 0 c0 1.
	   This bit can be written in Secure state only, with the following Read/Modify/Write code sequence:
	   MRC p15,0,rt,c15,c0,1
	   ORR rt,rt,#0x10
	   MCR p15,0,rt,c15,c0,1
	   When it is set, this bit causes the DMB instruction to be decoded and executed like a DSB.
	   Using this software workaround is not expected to have any impact on the overall performance
	   of the processor on a typical code base.
	 */
	mrc	p15, 0, r0, c15, c0, 1	@ read diagnostic register
	orr	r0, r0, #1 << 4		@ set bit #4
	mcr	p15, 0, r0, c15, c0, 1	@ write diagnostic register
#endif

#ifdef CONFIG_ARM_ERRATA_743622
	/* Read ARM® CortexTM-A9 processors r2 releases Software Developers Errata Notice
	   Errata: 2.4.1 (743622) Faulty logic in the Store Buffer might cause data corruption
	   Workaround
	   A software workaround is to set bit[6] in the undocumented Diagnostic Control register
	   placed in CP15 c15 0 c0 1.
	   You can write this bit in Secure state only, by using the following Read/Modify/Writ
	   code sequence:
	   MRC p15,0,rt,c15,c0,1 ORR rt,rt,#0x40
	   MCR p15,0,rt,c15,c0,1
	   The 'fast lookup' optimization in the Store Buffer is disabled when this bit is set.
	   This prevents the erratum occurring.
	   Setting this bit has no visible impact on the overall performance or power consumption
	   of the processor.
	*/

	mrc	p15, 0, r0, c15, c0, 1	@ read diagnostic register
	orr	r0, r0, #1 << 6		@ set bit #6
	mcr	p15, 0, r0, c15, c0, 1	@ write diagnostic register
#endif

#ifdef CONFIG_ARM_ERRATA_751472
	/* Errata: (751472) An interrupted ICIALLUIS operation might prevent the completion
	   of a following broadcast operation
	   Workaround
	   A software workaround for this erratum is to set bit[11] in the undocumented
	   Diagnostic Control register placed in CP15 c15 0 c0 1.
	   You can write this bit in Secure state only, by using the following Read/Modify/Write code sequence:
	   MRC p15,0,rt,c15,c0,1
	   ORR rt,rt,#0x800
	   MCR p15,0,rt,c15,c0,1
	   When it is set, this bit prevents the interruption of CP15 maintenance operations.
	   There is unlikely to be any visible impact on system performance when using this software workaround.
	 */

	mrc	p15, 0, r0, c15, c0, 1	@ read diagnostic register
	orr	r0, r0, #1 << 11	@ set bit #11
	mcr	p15, 0, r0, c15, c0, 1	@ write diagnostic register
#endif
#ifdef CONFIG_ARM_ERRATA_761320
	/*
	   Errata: (761320) Full cache line writes to the same memory region from at least two
	   processors might deadlock the processor.
	   Workaround
	   This erratum can be worked round by setting bit[21] of the undocumented Diagnostic
	   Control Register to 1. This register is encoded as CP15 c15 0 c0 1.
	   The bit can be written in Secure state only, with the following Read/Modify/Write code sequence:
	   MRC p15,0,rt,c15,c0,1
	   ORR rt,rt,#0x200000 MCR p15,0,rt,c15,c0,1
	   When this bit is set, the "direct eviction" optimization in the Bus Interface Unit is disabled,
	   which means this erratum cannot occur.
	   Setting this bit might prevent the Cortex-A9 from utilizing the full bandwidth when performing
	   intensive full cache line writes, and therefore a slight performance drop might be visible.
	 */
	mrc	p15, 0, r0, c15, c0, 1	@ read diagnostic register
	orr	r0, r0, #1 << 21	@ set bit #21
	mcr	p15, 0, r0, c15, c0, 1	@ write diagnostic register
#endif

	mov	r5, lr			@ Store my Caller
	mrc	p15, 0, r1, c0, c0, 0	@ r1 has Read Main ID Register (MIDR)
	mov	r3, r1, lsr #20		@ get variant field
	and	r3, r3, #0xf		@ r3 has CPU variant
	and	r4, r1, #0xf		@ r4 has CPU revision
	mov	r2, r3, lsl #4		@ shift variant field for combined value
	orr	r2, r4, r2		@ r2 has combined CPU variant + revision

#ifdef CONFIG_ARM_ERRATA_798870
	cmp	r2, #0x30		@ Applies to lower than R3p0
	bge	skip_errata_798870      @ skip if not affected rev
	cmp	r2, #0x20		@ Applies to including and above R2p0
	blt	skip_errata_798870      @ skip if not affected rev

	mrc	p15, 1, r0, c15, c0, 0  @ read l2 aux ctrl reg
	orr	r0, r0, #1 << 7         @ Enable hazard-detect timeout
	push	{r1-r5}			@ Save the cpu info registers
	bl	v7_arch_cp15_set_l2aux_ctrl
	isb				@ Recommended ISB after l2actlr update
	pop	{r1-r5}			@ Restore the cpu info - fall through
skip_errata_798870:
#endif

#ifdef CONFIG_ARM_ERRATA_454179
	cmp	r2, #0x21		@ Only on < r2p1
	bge	skip_errata_454179

	mrc	p15, 0, r0, c1, c0, 1	@ Read ACR
	orr	r0, r0, #(0x3 << 6)	@ Set DBSM(BIT7) and IBE(BIT6) bits
	push	{r1-r5}			@ Save the cpu info registers
	bl	v7_arch_cp15_set_acr
	pop	{r1-r5}			@ Restore the cpu info - fall through

skip_errata_454179:
#endif

#ifdef CONFIG_ARM_ERRATA_430973
	cmp	r2, #0x21		@ Only on < r2p1
	bge	skip_errata_430973

	mrc	p15, 0, r0, c1, c0, 1	@ Read ACR
	orr	r0, r0, #(0x1 << 6)	@ Set IBE bit
	push	{r1-r5}			@ Save the cpu info registers
	bl	v7_arch_cp15_set_acr
	pop	{r1-r5}			@ Restore the cpu info - fall through

skip_errata_430973:
#endif

#ifdef CONFIG_ARM_ERRATA_621766
	cmp	r2, #0x21		@ Only on < r2p1
	bge	skip_errata_621766

	mrc	p15, 0, r0, c1, c0, 1	@ Read ACR
	orr	r0, r0, #(0x1 << 5)	@ Set L1NEON bit
	push	{r1-r5}			@ Save the cpu info registers
	bl	v7_arch_cp15_set_acr
	pop	{r1-r5}			@ Restore the cpu info - fall through

skip_errata_621766:
#endif

	mov	pc, r5			@ back to my caller
ENDPROC(cpu_init_cp15)

#ifndef CONFIG_SKIP_LOWLEVEL_INIT
/*************************************************************************
 *
 * CPU_init_critical registers
 *
 * setup important registers
 * setup memory timing
 *
 *************************************************************************/
ENTRY(cpu_init_crit)
	/*
	 * Jump to board specific initialization...
	 * The Mask ROM will have already initialized
	 * basic memory. Go here to bump up clock rate and handle
	 * wake up conditions.
	 */
	b	lowlevel_init		@ go setup pll,mux,memory
ENDPROC(cpu_init_crit)
#endif
