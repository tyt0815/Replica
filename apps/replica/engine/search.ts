import {collectItems, dedupeItems, rankSearchItems} from '../../../vendor/YMusicV4/engine-js/src/logic/yt/parse';

export function videos(data: unknown) {
  return rankSearchItems(dedupeItems(collectItems(data)))
    .filter(item => item.kind === 'video')
    .map(item => ({
      id: item.id,
      title: item.title,
      artist: item.channelTitle ?? item.subtitleLine1 ?? '',
      thumbnail: item.thumbs?.at(-1)?.url ?? '',
    }));
}
