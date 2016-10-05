# -*- coding: utf-8 -*-
import argparse, json, sys, re, os, datetime, struct
kAuPerAngstrom = 1.8897259885789  # Length.
kPsecPerAu = 2.418884326505e-5  # Time.
kSizeOfReal = 8

def get_real_array(split_dir, is_little_endian, element):
    if element == []:
        return []
    elif isinstance(element[0], basestring):  # Supposed to be binary output mode.
        first = element[1]
        last = element[2]
        count = last - first + 1
        with open(os.path.join(split_dir, element[0]), 'rb') as fp:
            fp.seek(kSizeOfReal * (first - 1), os.SEEK_SET)
            xs_str = fp.read(kSizeOfReal * count)
        format_char_endian = '<' if is_little_endian else '>'
        return struct.unpack(format_char_endian + str(count) + 'd', xs_str)
    else:
        return element

def get_input_step_info(split_dir, is_little_endian, out, input_step):
    for s in out['structures']:
        if s['input_step'] == input_step:
            eigenvalues = get_real_array(split_dir, is_little_endian, s['eigenvalues'])
            means = get_real_array(split_dir, is_little_endian, s['eigenstate_mean_z'])
            msds = get_real_array(split_dir, is_little_endian, s['eigenstate_msd_total'])
            return (eigenvalues, means, msds)
    assert(False)  # Specified input_step not found.

def read_and_write_step(state, split_dir, is_little_endian,
                        fst_filter, num_filter, input_step_info, header):
    t = state['time']
    s = state['step_num']
    actual_msd = state['charge_coordinate_msd'][3]
    alpha_real = get_real_array(split_dir, is_little_endian, state['alpha']['real'])
    alpha_imag = get_real_array(split_dir, is_little_endian, state['alpha']['imag'])
    alpha_weights = map(lambda (r, i): r ** 2.0 + i ** 2.0, zip(alpha_real, alpha_imag))
    (eigenvalues, means, msds) = input_step_info
    assert(len(eigenvalues) == len(alpha_weights) == num_filter)
    state_zipped = zip(range(fst_filter, fst_filter + num_filter), eigenvalues, means, msds, alpha_weights)
    state_zipped_innegligible = filter(lambda state: state[4] > 1e-8, state_zipped)

    (indices, eigenvalues, means, msds, alpha_weights) = map(list, zip(*state_zipped_innegligible))
    output = {'time': t, 'step_num': s, 'actual_msd': actual_msd,
              'indices': indices, 'fst_filter': fst_filter, 'num_filter': num_filter,
              'eigenvalues': eigenvalues, 'means': means, 'msds': msds, 'alpha_weights': alpha_weights}
    with open('%s_%06d_alpha_distribution.json' % (header, s), 'w') as fp:
        json.dump(output, fp)

def calc(wavepacket_out, stride, wavepacket_out_path, is_little_endian, start_time, time_end):
    cond = wavepacket_out['condition']
    # Common.
    dim = cond['dim']
    ts = []
    # Alpha
    fst_filter = wavepacket_out['setting']['fst_filter']
    num_filter = wavepacket_out['setting']['end_filter'] - fst_filter + 1

    assert(wavepacket_out['setting']['is_output_split'])
    split_dir = os.path.dirname(wavepacket_out_path)
    header = re.sub('\.[^.]+$', '', wavepacket_out_path)
    for meta in wavepacket_out['split_files_metadata']:
        path = os.path.join(split_dir, meta['filename'])
        with open(path, 'r') as fp:
            diff = datetime.datetime.now() - start_time
            sys.stderr.write(str(diff) + ' reading: ' + path + '\n')
            states_split = json.load(fp)
        for state in states_split['states']:
            if state['step_num'] % stride == 0:
                input_step_info = get_input_step_info(split_dir, is_little_endian, states_split, state['input_step'])
                read_and_write_step(state, split_dir, is_little_endian,
                                    fst_filter, num_filter, input_step_info, header)
                if (not time_end is None) and (state['time'] * kPsecPerAu >= time_end):
                    return

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='')
    parser.add_argument('wavepacket_out_path', metavar='JSON', type=str,
                        help='')
    parser.add_argument('-s', metavar='STRIDE', dest='skip_stride_num', type=int, default=1,
                        help='')
    parser.add_argument('-e', metavar='TIME_END', dest='time_end', type=float, default=None,
                        help='[ps]')
    parser.add_argument('--big-endian', action='store_false', dest='is_little_endian',
                        default=True, help='')
    args = parser.parse_args()

    start_time = datetime.datetime.now()

    if not os.path.isfile(args.wavepacket_out_path):
        sys.stderr.write('file ' + args.wavepacket_out_path + ' does not exist\n')
        sys.exit(1)

    with open(args.wavepacket_out_path, 'r') as fp:
        wavepacket_out = json.load(fp)
    calc(wavepacket_out, args.skip_stride_num, args.wavepacket_out_path,
         args.is_little_endian, start_time, args.time_end)
