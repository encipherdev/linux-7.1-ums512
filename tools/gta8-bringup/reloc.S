	.text
	.globl _start
_start:
	b	code			// code0
	.word	0			// code1
	.quad	0x80000			// text_offset (stock-compatible)
	.quad	0			// image_size, patched by packer
	.quad	0x0a			// flags: LE, 4K, any phys
	.quad	0, 0, 0			// res2-4
	.ascii	"ARMd"			// magic
	.word	0			// res5
code:
	/* x0 = dtb from bootloader; keep x0-x3 untouched */
	adr	x9, payload		// src start
	ldr	x10, payload_size
	adr	x11, _start
	mov	x16, #0x1fffff
	add	x11, x11, x16
	and	x11, x11, #~0x1fffff	// dst = next 2MB boundary
	add	x12, x9, x10		// src end
	add	x13, x11, x10		// dst end
1:	ldp	x14, x15, [x12, #-16]!	// backward copy (dst > src, overlapping)
	stp	x14, x15, [x13, #-16]!
	cmp	x12, x9
	b.hi	1b
	dsb	sy
	ic	iallu
	dsb	sy
	isb
	br	x11
	.balign 8
payload_size:
	.quad	0			// patched by packer
	.balign 4096
payload:
