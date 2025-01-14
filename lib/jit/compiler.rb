require_relative 'assembler'

module JIT
  class Compiler
    # Utilities to call C functions and interact with the Ruby VM.
    # See: https://github.com/ruby/ruby/blob/master/rjit_c.rb
    C = RubyVM::RJIT::C

    # Metadata for each YARV instruction.
    INSNS = RubyVM::RJIT::INSNS

    # Size of the JIT buffer
    JIT_BUF_SIZE = 1024 * 1024

    STACK = [:r8, :r9, :r10, :r11]
    EC = :rdi
    CFP = :rsi

    # Initialize a JIT buffer. Called only once.
    def initialize
      # Allocate 64MiB of memory. This returns the memory address.
      @jit_buf = C.mmap(JIT_BUF_SIZE)
      # The number of bytes that have been written to @jit_buf.
      @jit_pos = 0
    end

    # Compile a method. Called after --rjit-call-threshold calls.
    def compile(iseq)
      # Write machine code to this assembler.
      asm = Assembler.new

      # Iterate over each YARV instruction.
      insn_index = 0
      stack_size = 0
      while insn_index < iseq.body.iseq_size
        insn = INSNS.fetch(C.rb_vm_insn_decode(iseq.body.iseq_encoded[insn_index]))
        case insn.name
        in :nop
          # none
        in :putnil
          asm.mov(STACK[stack_size], C.to_value(nil))
          stack_size += 1
        in :putobject_INT2FIX_1_
          asm.mov(STACK[stack_size], C.to_value(1))
          stack_size += 1
        in :putobject
          operand = iseq.body.iseq_encoded[insn_index + 1]
          asm.mov(STACK[stack_size], operand)
          stack_size += 1
        in :opt_plus
          recv = STACK[stack_size - 2]
          obj = STACK[stack_size - 1]

          asm.add(recv, obj)
          asm.sub(recv, 1)

          stack_size -= 1
        in :opt_minus
          recv = STACK[stack_size - 2]
          obj = STACK[stack_size - 1]

          asm.sub(recv, obj)
          asm.add(recv, 1)

          stack_size -= 1
        in :getlocal_WC_0
          # Get EP
          asm.mov(:rax, [CFP, C.rb_control_frame_t.offsetof(:ep)])

          # Load the local variable
          idx = iseq.body.iseq_encoded[insn_index + 1]
          asm.mov(STACK[stack_size], [:rax, -idx * C.VALUE.size])

          stack_size += 1
        in :leave
          asm.add(CFP, C.rb_control_frame_t.size)
          asm.mov([EC, C.rb_execution_context_t.offsetof(:cfp)], CFP)
          asm.mov(:rax, STACK[stack_size - 1])
          asm.ret
        end
        insn_index += insn.len
      end

      # Write machine code into memory and use it as a JIT function.
      iseq.body.jit_func = write(asm)
    rescue Exception => e
      abort e.full_message
    end

    private

    # Write bytes in a given assembler into @jit_buf.
    # @param asm [JIT::Assembler]
    def write(asm)
      jit_addr = @jit_buf + @jit_pos

      # Append machine code to the JIT buffer
      C.mprotect_write(@jit_buf, JIT_BUF_SIZE) # make @jit_buf writable
      @jit_pos += asm.assemble(jit_addr)
      C.mprotect_exec(@jit_buf, JIT_BUF_SIZE) # make @jit_buf executable

      # Dump disassembly if --rjit-dump-disasm
      if C.rjit_opts.dump_disasm
        C.dump_disasm(jit_addr, @jit_buf + @jit_pos).each do |address, mnemonic, op_str|
          puts "  0x#{format("%x", address)}: #{mnemonic} #{op_str}"
        end
        puts
      end

      jit_addr
    end
  end
end
