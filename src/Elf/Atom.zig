const Atom = @This();

const std = @import("std");
const elf = std.elf;
const log = std.log.scoped(.elf);
const mem = std.mem;

const Allocator = mem.Allocator;
const Elf = @import("../Elf.zig");

/// Each decl always gets a local symbol with the fully qualified name.
/// The vaddr and size are found here directly.
/// The file offset is found by computing the vaddr offset from the section vaddr
/// the symbol references, and adding that to the file offset of the section.
/// If this field is 0, it means the codegen size = 0 and there is no symbol or
/// offset table entry.
local_sym_index: u32,

/// null means global synthetic symbol table.
file: ?u32,

/// List of symbol aliases pointing to the same atom via different entries
aliases: std.ArrayListUnmanaged(u32) = .{},

/// List of symbols contained within this atom
contained: std.ArrayListUnmanaged(SymbolAtOffset) = .{},

/// Code (may be non-relocated) this atom represents
code: std.ArrayListUnmanaged(u8) = .{},

/// Size of this atom
/// TODO is this really needed given that size is a field of a symbol?
size: u32,

/// Alignment of this atom. Unlike in MachO, minimum alignment is 1.
alignment: u32,

/// List of relocations belonging to this atom.
relocs: std.ArrayListUnmanaged(elf.Elf64_Rela) = .{},

/// Points to the previous and next neighbours
next: ?*Atom,
prev: ?*Atom,

pub const SymbolAtOffset = struct {
    local_sym_index: u32,
    offset: u64,

    pub fn format(
        self: SymbolAtOffset,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try std.fmt.format(writer, "{{ {d}: .offset = {d} }}", .{ self.local_sym_index, self.offset });
    }
};

pub fn createEmpty(allocator: *Allocator) !*Atom {
    const self = try allocator.create(Atom);
    self.* = .{
        .local_sym_index = 0,
        .file = undefined,
        .size = 0,
        .alignment = 0,
        .prev = null,
        .next = null,
    };
    return self;
}

pub fn deinit(self: *Atom, allocator: *Allocator) void {
    self.relocs.deinit(allocator);
    self.code.deinit(allocator);
    self.contained.deinit(allocator);
    self.aliases.deinit(allocator);
}

pub fn format(self: Atom, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    _ = fmt;
    _ = options;
    try std.fmt.format(writer, "Atom {{ ", .{});
    try std.fmt.format(writer, "  .local_sym_index = {d}, ", .{self.local_sym_index});
    try std.fmt.format(writer, "  .file = {d}, ", .{self.file});
    try std.fmt.format(writer, "  .aliases = {any}, ", .{self.aliases.items});
    try std.fmt.format(writer, "  .contained = {any}, ", .{self.contained.items});
    try std.fmt.format(writer, "  .code = {x}, ", .{std.fmt.fmtSliceHexLower(if (self.code.items.len > 64)
        self.code.items[0..64]
    else
        self.code.items)});
    try std.fmt.format(writer, "  .size = {d}, ", .{self.size});
    try std.fmt.format(writer, "  .alignment = {d}, ", .{self.alignment});
    try std.fmt.format(writer, "  .relocs = {any}, ", .{self.relocs.items});
    try std.fmt.format(writer, "}}", .{});
}

fn getSymbol(self: Atom, elf_file: *Elf, index: u32) elf.Elf64_Sym {
    if (self.file) |file| {
        const object = elf_file.objects.items[file];
        return object.symtab.items[index];
    } else {
        return elf_file.locals.items[index];
    }
}

pub fn resolveRelocs(self: *Atom, elf_file: *Elf) !void {
    const sym = self.getSymbol(elf_file, self.local_sym_index);
    const sym_name = if (self.file) |file|
        elf_file.objects.items[file].getString(sym.st_name)
    else
        elf_file.getString(sym.st_name);
    log.debug("resolving relocs in atom '{s}'", .{sym_name});

    for (self.relocs.items) |rel| {
        const r_sym = @intCast(u32, rel.r_info >> 32);
        const r_type = @truncate(u32, rel.r_info);
        const tsym = if (self.file) |file| blk: {
            const object = elf_file.objects.items[file];
            break :blk object.symtab.items[r_sym];
        } else elf_file.locals.items[r_sym];
        const tsym_name = if (self.file) |file| blk: {
            const object = elf_file.objects.items[file];
            break :blk object.getString(tsym.st_name);
        } else elf_file.getString(tsym.st_name);
        const tsym_st_bind = tsym.st_info >> 4;
        const tsym_st_type = tsym.st_info & 0xf;

        switch (r_type) {
            elf.R_X86_64_NONE => {},
            elf.R_X86_64_64 => {
                log.debug("R_X86_64_64: {x}: [() => 0x{x}] ({s})", .{ rel.r_offset, tsym.st_value, tsym_name });
                mem.writeIntLittle(u64, self.code.items[rel.r_offset..][0..8], tsym.st_value);
            },
            elf.R_X86_64_PC32 => {
                const source = @intCast(i64, sym.st_value + rel.r_offset);
                const target = @intCast(i64, tsym.st_value);
                const displacement = @intCast(i32, target - source + rel.r_addend);
                log.debug("R_X86_64_PC32: {x}: [0x{x} => 0x{x}] ({s})", .{
                    rel.r_offset,
                    source,
                    target,
                    tsym_name,
                });
                mem.writeIntLittle(i32, self.code.items[rel.r_offset..][0..4], displacement);
            },
            elf.R_X86_64_PLT32 => {
                const source = @intCast(i64, sym.st_value + rel.r_offset);
                const is_local = tsym_st_type == elf.STT_SECTION or tsym_st_bind == elf.STB_LOCAL;
                const target: i64 = blk: {
                    if (!is_local) {
                        const global = elf_file.globals.get(tsym_name).?;
                        if (global.file) |file| {
                            const actual_object = elf_file.objects.items[file];
                            const actual_tsym = actual_object.symtab.items[global.sym_index];
                            if (actual_tsym.st_info & 0xf == elf.STT_NOTYPE and
                                actual_tsym.st_shndx == elf.SHN_UNDEF)
                            {
                                log.debug("TODO handle R_X86_64_PLT32 to an UND symbol via PLT table", .{});
                                break :blk source;
                            }
                            break :blk @intCast(i64, actual_tsym.st_value);
                        } else {
                            const actual_tsym = elf_file.locals.items[global.sym_index];
                            break :blk @intCast(i64, actual_tsym.st_value);
                        }
                    }

                    break :blk @intCast(i64, tsym.st_value);
                };
                const displacement = @intCast(i32, target - source + rel.r_addend);
                log.debug("R_X86_64_PLT32: {x}: [0x{x} => 0x{x}] ({s})", .{
                    rel.r_offset,
                    source,
                    target,
                    tsym_name,
                });
                mem.writeIntLittle(i32, self.code.items[rel.r_offset..][0..4], displacement);
            },
            elf.R_X86_64_32 => {
                const target = @intCast(u32, @intCast(i64, tsym.st_value) + rel.r_addend);
                log.debug("R_X86_64_32: {x}: [() => 0x{x}] ({s})", .{ rel.r_offset, target, tsym_name });
                mem.writeIntLittle(u32, self.code.items[rel.r_offset..][0..4], target);
            },
            elf.R_X86_64_REX_GOTPCRELX => {
                const source = @intCast(i64, sym.st_value + rel.r_offset);
                const global = elf_file.globals.get(tsym_name).?;
                const target: i64 = blk: {
                    if (global.file) |file| {
                        const actual_object = elf_file.objects.items[file];
                        const actual_tsym = actual_object.symtab.items[global.sym_index];
                        if (actual_tsym.st_info & 0xf == elf.STT_NOTYPE and
                            actual_tsym.st_shndx == elf.SHN_UNDEF)
                        {
                            log.debug("TODO handle R_X86_64_REX_GOTPCRELX to an UND symbol via GOT", .{});
                            break :blk source;
                        }
                        break :blk @intCast(i64, actual_tsym.st_value);
                    } else {
                        const actual_tsym = elf_file.locals.items[global.sym_index];
                        break :blk @intCast(i64, actual_tsym.st_value);
                    }
                };

                const full_inst = self.code.items[rel.r_offset - 3 ..][0..7];
                log.debug("R_X86_64_REX_GOTPCRELX: {x}: [0x{x} => 0x{x}] ({s})", .{
                    rel.r_offset,
                    source,
                    target,
                    tsym_name,
                });
                log.debug("  => {x}", .{std.fmt.fmtSliceHexLower(full_inst)});

                const displacement = @intCast(i32, target - source + rel.r_addend);
                mem.writeIntLittle(i32, self.code.items[rel.r_offset..][0..4], displacement);
            },
            else => {
                const source = @intCast(i64, sym.st_value + rel.r_offset);
                log.debug("TODO {d}: {x}: [0x{x} => 0x{x}] ({s})", .{
                    r_type,
                    rel.r_offset,
                    source,
                    tsym.st_value,
                    tsym_name,
                });
            },
        }
    }
}
